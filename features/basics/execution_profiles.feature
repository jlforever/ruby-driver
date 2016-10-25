Feature: Execution profiles

  Execution profiles allow a user to group various execution options into a 'profile'. A user can then execute
  statements with different profiles by specifying the profile name.

  Background:
    Given a running cassandra cluster

  Scenario: Creating and inspecting execution profiles
    Given the following example:
      """ruby
      require 'cassandra'

      profile_1 = Cassandra::Execution::Profile.new(load_balancing_policy: Cassandra::LoadBalancing::Policies::RoundRobin.new,
                                                    retry_policy: Cassandra::Retry::Policies::DowngradingConsistency.new,
                                                    consistency: :all,
                                                    timeout: 32
      )

      cluster = Cassandra.cluster(execution_profiles: {'my_profile' => profile_1})
      puts "There are #{cluster.execution_profiles.size} execution profiles in the cluster:"
      puts ""

      cluster.execution_profiles.each do |name, profile|
        puts "Name: #{name}"
        puts "Load_balancing_policy: #{profile.load_balancing_policy.class}"
        puts "Retry policy: #{profile.retry_policy.class}"
        puts "Consistency: #{profile.consistency}"
        puts "Timeout: #{profile.timeout}"
        puts ""
      end
      """
    When it is executed
    Then its output should contain:
      """
      There are 2 execution profiles in the cluster:

      Name: __DEFAULT_EXECUTION_PROFILE__
      Load_balancing_policy: Cassandra::LoadBalancing::Policies::TokenAware
      Retry policy: Cassandra::Retry::Policies::Default
      Consistency: local_one
      Timeout: 12

      Name: my_profile
      Load_balancing_policy: Cassandra::LoadBalancing::Policies::RoundRobin
      Retry policy: Cassandra::Retry::Policies::DowngradingConsistency
      Consistency: all
      Timeout: 32
      """

  Scenario: Configure different load balancing policies with profiles
    Given the following example:
      """ruby
      require 'cassandra'

      include Cassandra::LoadBalancing::Policies
      profiles = {
          p1: Cassandra::Execution::Profile.new(load_balancing_policy: WhiteList.new(['127.0.0.1'], RoundRobin.new)),
          p2: Cassandra::Execution::Profile.new(load_balancing_policy: WhiteList.new(['127.0.0.2'], RoundRobin.new))
      }

      cluster = Cassandra.cluster(execution_profiles: profiles)
      session = cluster.connect

      puts "Running with default profile"

      # By default, the driver uses a token-aware, round-robin load balancing policy.
      ip_list = []
      3.times do
        rs = session.execute('select rpc_address from system.local')
        ip_list << rs.first['rpc_address'].to_s
      end
      puts ip_list.sort.join("\n")

      # p2 and p3 set up load-balancing policies that will match only one node.
      puts "Running with profile p1"
      3.times do
        rs = session.execute('select rpc_address from system.local', execution_profile: :p1)
        puts rs.first['rpc_address']
      end

      puts "Running with profile p2"
      3.times do
        rs = session.execute('select rpc_address from system.local', execution_profile: :p2)
        puts rs.first['rpc_address']
      end
      """
    When it is executed
    Then its output should contain:
      """
      Running with default profile
      127.0.0.1
      127.0.0.2
      127.0.0.3
      Running with profile p1
      127.0.0.1
      127.0.0.1
      127.0.0.1
      Running with profile p2
      127.0.0.2
      127.0.0.2
      127.0.0.2
      """

