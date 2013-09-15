# encoding: utf-8

module Cql
  module Client
    # @private
    class AsynchronousClient < Client
      def initialize(options={})
        @connection_timeout = options[:connection_timeout] || 10
        @hosts = extract_hosts(options)
        @port = options[:port] || 9042
        @logger = options[:logger] || NullLogger.new
        @io_reactor = options[:io_reactor] || Io::IoReactor.new(Protocol::CqlProtocolHandler)
        @lock = Mutex.new
        @connected = false
        @connecting = false
        @closing = false
        @initial_keyspace = options[:keyspace]
        @credentials = options[:credentials]
        @request_runner = RequestRunner.new
        @connection_manager = ConnectionManager.new
      end

      def connect
        @lock.synchronize do
          return @connected_future if can_execute?
          @connecting = true
          @connected_future = begin
            if @closing
              f = @closed_future
              f = f.flat_map { setup_connections }
              f = f.fallback { setup_connections }
            else
              f = setup_connections
            end
            f.on_value do |connections|
              @connection_manager.add_connections(connections)
              register_event_listener(@connection_manager.random_connection)
            end
            f.map { self }
          end
        end
        @connected_future.on_complete(&method(:connected))
        @connected_future
      end

      def close
        @lock.synchronize do
          return @closed_future if @closing
          @closing = true
          @closed_future = begin
            if @connecting
              f = @connected_future
              f = f.flat_map { @io_reactor.stop }
              f = f.fallback { @io_reactor.stop }
            else
              f = @io_reactor.stop
            end
            f.map { self }
          end
        end
        @closed_future.on_complete(&method(:closed))
        @closed_future
      end

      def connected?
        @connected
      end

      def keyspace
        @connection_manager.random_connection.keyspace
      end

      def use(keyspace)
        with_failure_handler do
          connections = @connection_manager.select { |c| c.keyspace != keyspace }
          if connections.any?
            futures = connections.map { |connection| use_keyspace(keyspace, connection) }
            Future.all(*futures).map { nil }
          else
            Future.resolved
          end
        end
      end

      def execute(cql, consistency=nil)
        with_failure_handler do
          consistency ||= DEFAULT_CONSISTENCY_LEVEL
          execute_request(Protocol::QueryRequest.new(cql, consistency))
        end
      end

      def prepare(cql)
        with_failure_handler do
          AsynchronousPreparedStatement.prepare(cql, @connection_manager, @logger)
        end
      end

      private

      KEYSPACE_NAME_PATTERN = /^\w[\w\d_]*$|^"\w[\w\d_]*"$/
      DEFAULT_CONSISTENCY_LEVEL = :quorum

      class FailedConnection
        attr_reader :error, :host, :port

        def initialize(error, host, port)
          @error = error
          @host = host
          @port = port
        end

        def connected?
          false
        end
      end

      def extract_hosts(options)
        if options[:hosts]
          options[:hosts].uniq
        elsif options[:host]
          options[:host].split(',').uniq
        else
          %w[localhost]
        end
      end

      def connected(f)
        if f.resolved?
          @lock.synchronize do
            @connecting = false
            @connected = true
          end
          @logger.info('Cluster connection complete')
        else
          @lock.synchronize do
            @connecting = false
            @connected = false
          end
          f.on_failure do |e|
            @logger.error('Failed connecting to cluster: %s' % e.message)
          end
          close
        end
      end

      def closed(f)
        @lock.synchronize do
          @closing = false
          @connected = false
          if f.resolved?
            @logger.info('Cluster disconnect complete')
          else
            f.on_failure do |e|
              @logger.error('Cluster disconnect failed: %s' % e.message)
            end
          end
        end
      end

      def can_execute?
        !@closing && (@connecting || (@connected && @connection_manager.connected?))
      end

      def valid_keyspace_name?(name)
        name =~ KEYSPACE_NAME_PATTERN
      end

      def with_failure_handler
        return Future.failed(NotConnectedError.new) unless can_execute?
        yield
      rescue => e
        Future.failed(e)
      end

      def register_event_listener(connection)
        register_request = Protocol::RegisterRequest.new(Protocol::TopologyChangeEventResponse::TYPE, Protocol::StatusChangeEventResponse::TYPE)
        execute_request(register_request, connection)
        connection.on_closed do
          if connected?
            begin
              register_event_listener(@connection_manager.random_connection)
            rescue NotConnectedError
              # we had started closing down after the connection check
            end
          end
        end
        connection.on_event do |event|
          begin
            if event.change == 'UP'
              @logger.debug('Received UP event')
              handle_topology_change
            end
          end
        end
      end

      def handle_topology_change
        seed_connections = @connection_manager.snapshot
        f = discover_peers(seed_connections, keyspace)
        f.on_value do |connections|
          connected_connections = connections.select(&:connected?)
          if connected_connections.any?
            @connection_manager.add_connections(connected_connections)
          else
            @logger.debug('Scheduling new peer discovery in 1s')
            f = @io_reactor.schedule_timer(1)
            f.on_value do
              handle_topology_change
            end
          end
        end
      end

      def discover_peers(seed_connections, initial_keyspace)
        @logger.debug('Looking for additional nodes')
        connection = seed_connections.sample
        return Future.resolved([]) unless connection
        request = Protocol::QueryRequest.new('SELECT peer, data_center, host_id, rpc_address FROM system.peers', :one)
        peer_info = execute_request(request, connection)
        peer_info.flat_map do |result|
          seed_dcs = seed_connections.map { |c| c[:data_center] }.uniq
          unconnected_peers = result.select do |row|
            seed_dcs.include?(row['data_center']) && seed_connections.none? { |c| c[:host_id] == row['host_id'] }
          end
          @logger.debug('%d additional nodes found' % unconnected_peers.size)
          node_addresses = unconnected_peers.map do |row|
            rpc_address = row['rpc_address'].to_s
            if rpc_address == '0.0.0.0'
              row['peer'].to_s
            else
              rpc_address
            end
          end
          if node_addresses.any?
            connect_to_hosts(node_addresses, initial_keyspace, false)
          else
            Future.resolved([])
          end
        end
      end

      def setup_connections
        f = @io_reactor.start.flat_map do
          connect_to_hosts(@hosts, @initial_keyspace, true)
        end
        f = f.map do |connections|
          connected_connections = connections.select(&:connected?)
          if connected_connections.empty?
            e = connections.first.error
            if e.is_a?(Cql::QueryError) && e.code == 0x100
              e = AuthenticationError.new(e.message)
            end
            raise e
          end
          connected_connections
        end
        f
      end

      def connect_to_hosts(hosts, initial_keyspace, peer_discovery)
        connection_futures = hosts.map do |host|
          connect_to_host(host, initial_keyspace).recover do |error|
            FailedConnection.new(error, host, @port)
          end
        end
        connection_futures.each do |cf|
          cf.on_value do |c|
            if c.is_a?(FailedConnection)
              @logger.warn('Failed connecting to node at %s:%d: %s' % [c.host, c.port, c.error.message])
            else
              @logger.info('Connected to node %s at %s:%d in data center %s' % [c[:host_id], c.host, c.port, c[:data_center]])
            end
            c.on_closed do
              @logger.warn('Connection to node %s at %s:%d in data center %s unexpectedly closed' % [c[:host_id], c.host, c.port, c[:data_center]])
            end
          end
        end
        hosts_connected_future = Future.all(*connection_futures)
        if peer_discovery
          hosts_connected_future.flat_map do |connections|
            discover_peers(connections.select(&:connected?), initial_keyspace).map do |peer_connections|
              connections + peer_connections
            end
          end
        else
          hosts_connected_future
        end
      end

      def connect_to_host(host, keyspace)
        @logger.debug('Connecting to node at %s:%d' % [host, @port])
        connected = @io_reactor.connect(host, @port, @connection_timeout)
        connected.flat_map do |connection|
          initialize_connection(connection, keyspace)
        end
      end

      def initialize_connection(connection, keyspace)
        started = execute_request(Protocol::StartupRequest.new, connection)
        authenticated = started.flat_map { |response| maybe_authenticate(response, connection) }
        identified = authenticated.flat_map { identify_node(connection) }
        identified.flat_map { use_keyspace(keyspace, connection) }
      end

      def identify_node(connection)
        request = Protocol::QueryRequest.new('SELECT data_center, host_id FROM system.local', :one)
        f = execute_request(request, connection)
        f.on_value do |result|
          unless result.empty?
            connection[:host_id] = result.first['host_id']
            connection[:data_center] = result.first['data_center']
          end
        end
        f
      end

      def use_keyspace(keyspace, connection)
        return Future.resolved(connection) unless keyspace
        return Future.failed(InvalidKeyspaceNameError.new(%("#{keyspace}" is not a valid keyspace name))) unless valid_keyspace_name?(keyspace)
        execute_request(Protocol::QueryRequest.new("USE #{keyspace}", :one), connection).map { connection }
      end

      def maybe_authenticate(response, connection)
        case response
        when AuthenticationRequired
          if @credentials
            credentials_request = Protocol::CredentialsRequest.new(@credentials)
            execute_request(credentials_request, connection).map { connection }
          else
            Future.failed(AuthenticationError.new('Server requested authentication, but no credentials given'))
          end
        else
          Future.resolved(connection)
        end
      end

      def execute_request(request, connection=nil)
        f = @request_runner.execute(connection || @connection_manager.random_connection, request)
        f.map do |result|
          if result.is_a?(KeyspaceChanged)
            use(result.keyspace)
            nil
          else
            result
          end
        end
      end
    end
  end
end
