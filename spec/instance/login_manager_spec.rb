#
# Copyright (c) 2009-2011 RightScale Inc
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

require File.join(File.dirname(__FILE__), 'spec_helper')

describe RightScale::LoginManager do
  include RightScale::SpecHelper

  RIGHTSCALE_KEYS_FILE = '/home/rightscale/.ssh/authorized_keys'
  RIGHTSCALE_ACCOUNT_CREDS = {:user=>"rightscale", :group=>"rightscale"}

  # equivalent of x.minutes for dev setup without activesupport
  def minutes(count)
    return count * 60
  end

  #given a scalar value, return a range encompassing that value plus or minus
  #n (where n = 3 by default)
  def approximately(t, n=3)
    return (t-n)..(t+n)
  end

  # equivalent of x.minutes.from_now for dev setup without activesupport
  def minutes_from_now(count)
    return Time.now + minutes(count)
  end

  # equivalent of 1.hours for dev setup without activesupport
  def one_hour
    return 60 * 60
  end

  # equivalent of 3.months for dev setup without activesupport
  def three_months
    return 60 * 60 * 24 * 90
  end

  # equivalent of 1.hours.from_now for dev setup without activesupport
  def one_hour_from_now
    return Time.now + one_hour
  end

  def three_months_from_now
    return Time.now + three_months
  end

  # equivalent of 1.hours.ago for dev setup without activesupport
  def one_hour_ago
    return Time.now - one_hour
  end

  # equivalent of 1.days.ago for dev setup without activesupport
  def one_day_ago
    return Time.now - 24 * one_hour
  end

  # Generates a LoginUser with specified number of public keys
  def generate_user(public_keys_count, domain, populated = nil, fingerprint_offset = nil)
    num = rand(2**32-4097)
    public_keys = []
    fingerprints = [] if fingerprint_offset

    public_keys_count.times do |i|
      pub = rand(2**32).to_s(32)
      public_keys << ((populated.nil? || populated[i]) ? "ssh-rsa #{pub} #{num}@#{domain}" : nil)
      fingerprints << "f#{i + fingerprint_offset}" if fingerprint_offset
    end

    RightScale::LoginUser.new("#{num}", "user#{num}", nil, "#{num}@#{domain}", true, nil, public_keys, nil, fingerprints)
  end

  # Generates a LoginPolicy with specified number of users, number of public keys populated,
  # and whether or not fingerprinted
  def generate_policy(created_at, users_count, populated = nil, fingerprinted = nil)
    populated_keys_range ||= (0..users_count + 1)
    policy = RightScale::LoginPolicy.new(audit_id = 1234, created_at)
    keys_count = 0
    users_count.times do |i|
      count = i == 1 ? 2 : 1
      offset = fingerprinted ? keys_count : nil
      policy.users << generate_user(count, "rightscale.com", populated && populated[keys_count..-1], offset)
      keys_count += count
    end
    policy
  end

  # Create mock for IdempotentRequest
  def mock_request(args = nil, result = nil, error = nil)
    request = flexmock("request")
    if result
      request.should_receive(:callback).and_yield(result).once
    else
      request.should_receive(:callback).once
    end
    if error
      request.should_receive(:errback).and_yield(error).once
    else
      request.should_receive(:errback).once
    end
    if args
      flexmock(RightScale::IdempotentRequest).should_receive(:new).with(*args).and_return(request).once
    else
      flexmock(RightScale::IdempotentRequest).should_receive(:new).and_return(request).once
    end
  end

  before(:each) do
    flexmock(RightScale::Log).should_receive(:debug).by_default
    @mgr = RightScale::LoginManager.instance
    @agent_identity = "rs-instance-1-1"
  end

  describe "#supported_by_platform" do
    context "when platform is not Linux" do
      before(:each) do
        flexmock(RightScale::Platform).should_receive(:linux?).and_return(false)
      end

      it "returns false" do
        @mgr.supported_by_platform?.should be(false)
      end
    end

    context "when platform is Linux" do
      before(:each) do
        flexmock(RightScale::Platform).should_receive(:linux?).and_return(true)
        flexmock(RightScale::Platform).should_receive(:darwin?).and_return(false)
        flexmock(RightScale::Platform).should_receive(:windows?).and_return(false)
      end

      context 'and rightscale user exists' do
        before(:each) do
          flexmock(@mgr).should_receive(:user_exists?).with('rightscale').and_return(true)
        end

        it "returns true" do
          @mgr.supported_by_platform?.should be(true)
        end
      end

      context 'and rightscale user does not exist' do
        before(:each) do
          flexmock(@mgr).should_receive(:user_exists?).with('rightscale').and_return(false)
        end

        it "returns false" do
          @mgr.supported_by_platform?.should be(false)
        end
      end

    end
  end

  describe "#update_policy" do
    before(:each) do
      flexmock(@mgr).should_receive(:supported_by_platform?).and_return(true).by_default

      # === Mocks for OS specific operations
      flexmock(@mgr).should_receive(:write_keys_file).and_return(true).by_default
      flexmock(@mgr).should_receive(:add_user).and_return(nil).by_default
      flexmock(@mgr).should_receive(:manage_group).and_return(true).by_default
      flexmock(@mgr).should_receive(:user_exists?).and_return(false).by_default
      flexmock(@mgr).should_receive(:uid_exists?).and_return(false).by_default
      # === Mocks end

      flexmock(RightScale::InstanceState).should_receive(:login_policy).and_return(nil).by_default
      flexmock(RightScale::InstanceState).should_receive(:login_policy=).by_default
      flexmock(RightScale::AgentTagsManager).should_receive("instance.add_tags")
      flexmock(@mgr).should_receive(:schedule_expiry)

      flexmock(RightScale::LoginUser).should_receive(:fingerprint).and_return("f1", "f2", "f3", "f4").by_default

      @policy = RightScale::LoginPolicy.new(1234, one_hour_ago)
      @user_keys = []
      3.times do |i|
        user = generate_user(i == 1 ? 2 : 1, "rightscale.com")
        @policy.users << user
        user.public_keys.each do |key|
          @user_keys << "#{@mgr.get_key_prefix(user.username, user.common_name, user.uuid, user.superuser,
                                               "http://example.com/#{user.username}.tgz")} #{key}"
        end
      end
    end

    it "should not add authorized_keys for expired users" do
      @policy.users[0].expires_at = one_day_ago

      flexmock(@mgr).should_receive(:read_keys_file).and_return([])
      flexmock(@mgr).should_receive(:write_keys_file) do |keys, file, options|
        keys.length.should == (@policy.users.size - 1)
      end

      @mgr.update_policy(@policy, @agent_identity)
    end
    
    it "should respect the superuser bit" do
      @policy.users[0].superuser = false
      flexmock(@mgr).should_receive(:read_keys_file).and_return([])
      flexmock(@mgr).should_receive(:manage_group).with('rightscale', :remove, @policy.users[0].username).ordered
      flexmock(@mgr).should_receive(:manage_group).with('rightscale', :add, @policy.users[1].username).ordered
      flexmock(@mgr).should_receive(:manage_group).with('rightscale', :add, @policy.users[2].username).ordered
      flexmock(@mgr).should_receive(:write_keys_file) do |keys, file, options|
        keys.length.should == @policy.users.size
      end
      @mgr.update_policy(@policy, @agent_identity)
    end
  end

  describe "#update_users" do
    before(:each) do
      flexmock(RightScale::LoginUser).should_receive(:fingerprint).and_return("f0", "f1", "f2", "f3").by_default
      @old_policy = generate_policy(one_day_ago, users_count = 2, populated = nil, fingerprinted = true)
      flexmock(RightScale::InstanceState).should_receive(:login_policy).and_return(@old_policy).by_default
    end

    it "should retrieve public keys that cannot be found in old policy" do
      mock_request(["/key_server/retrieve_public_keys", {:agent_identity => @agent_identity, :public_key_fingerprints => ["f3"]}],
                   {"f3" => "ssh-rsa key3"})
      policy = generate_policy(one_hour_ago, users_count = 3, populated = [true, false, true, false], fingerprinted = true)
      user0 = policy.users[0].dup
      user1 = policy.users[1].dup
      agent_identity = @agent_identity
      users, missing = @mgr.instance_eval { update_users(policy.users, agent_identity) }
      users[0].public_keys.should == user0.public_keys
      users[1].public_keys.should == [@old_policy.users[1].public_keys[0], user1.public_keys[1]]
      users[2].public_keys.should == ["ssh-rsa key3"]
      missing.should == []
    end

    it "should handle missing old policy" do
      flexmock(RightScale::InstanceState).should_receive(:login_policy).and_return(nil)
      mock_request(["/key_server/retrieve_public_keys", {:agent_identity => @agent_identity, :public_key_fingerprints => ["f3"]}],
                   {"f3" => "ssh-rsa key3"})
      policy = generate_policy(one_hour_ago, users_count = 3, populated = [true, true, true, false], fingerprinted = true)
      user0 = policy.users[0].dup
      user1 = policy.users[1].dup
      agent_identity = @agent_identity
      users, missing = @mgr.instance_eval { update_users(policy.users, agent_identity) }
      users[0].public_keys.should == user0.public_keys
      users[1].public_keys.should == user1.public_keys
      users[2].public_keys.should == ["ssh-rsa key3"]
      missing.should == []
    end

    it "should return users for which it could not retrieve a public key" do
      flexmock(RightScale::Log).should_receive(:error).with(/Failed to obtain public key with fingerprint f3 /).once
      mock_request(["/key_server/retrieve_public_keys", {:agent_identity => @agent_identity, :public_key_fingerprints => ["f3"]}], {})
      policy = generate_policy(one_hour_ago, users_count = 3, populated = [true, true, true, false], fingerprinted = true)
      user0 = policy.users[0].dup
      user1 = policy.users[1].dup
      user2 = policy.users[2].dup
      agent_identity = @agent_identity
      users, missing = @mgr.instance_eval { update_users(policy.users, agent_identity) }
      users[0].public_keys.should == user0.public_keys
      users[1].public_keys.should == user1.public_keys
      users[2].should be_nil
      missing.should == [user2]
    end

    it "should log an error if cannot retrieve a public key" do
      @old_policy = generate_policy(one_day_ago, users_count = 1, populated = nil, fingerprinted = true)
      flexmock(RightScale::InstanceState).should_receive(:login_policy).and_return(@old_policy)
      flexmock(RightScale::Log).should_receive(:error).with(/Failed to retrieve public keys for users /).once
      flexmock(RightScale::Log).should_receive(:error).with(/Failed to obtain public key with fingerprint f[1,3] /).twice
      mock_request(["/key_server/retrieve_public_keys", {:agent_identity => @agent_identity, :public_key_fingerprints => ["f1", "f3"]}],
                   nil, "error during retrieval")
      policy = generate_policy(one_hour_ago, users_count = 3, populated = [true, false, true, false], fingerprinted = true)
      user0 = policy.users[0].dup
      user1 = policy.users[1].dup
      user2 = policy.users[2].dup
      agent_identity = @agent_identity
      users, missing = @mgr.instance_eval { update_users(policy.users, agent_identity) }
      users[0].should == user0
      users[1].public_keys.should == [user1.public_keys[1]]
      users[2].should be_nil
      missing.map { |u| u.username }.should == [user1.username, user2.username]
    end
  end

  describe "#describe_policy" do
    before(:each) do
      flexmock(RightScale::LoginUser).should_receive(:fingerprint).and_return("f")
      @policy = generate_policy(one_day_ago, users_count = 4)
    end

    it "should show number of users and superusers" do
      policy = @policy
      @mgr.instance_eval {
        describe_policy(policy.users, policy.users[2, 1]).should == "4 authorized users (3 normal, 1 superuser).\n"
      }
    end

    it "should show number of users missing and" do
      policy = @policy
      @mgr.instance_eval {
        describe_policy(policy.users[0, 3], policy.users[2, 1], policy.users[3, 1]).should ==
            "3 authorized users (2 normal, 1 superuser).\nPublic key missing for #{policy.users[3].username}.\n"
      }
    end
  end

  describe "#schedule_expiry" do
    before(:each) do
      @policy = RightScale::LoginPolicy.new(1234, one_hour_ago)
      @superuser_keys = []
    end

    context 'when no users are set to expire' do
      before(:each) do
        u1 = RightScale::LoginUser.new("1234", "rs1234", "ssh-rsa aaa 1234@rightscale.com", "1234@rightscale.com", true, nil)
        u2 = RightScale::LoginUser.new("2345", "rs2345", nil, "2345@rightscale.com", true, nil, ["ssh-rsa bbb 2345@rightscale.com"])
        @policy.users << u1
        @policy.users << u2
      end

      it 'should not create a timer' do
        flexmock(EventMachine::Timer).should_receive(:new).never
        policy = @policy
        @mgr.instance_eval {
          schedule_expiry(policy, @agent_identity).should == false
        }
      end
    end

    context 'when a user will expire in 90 days' do
      before(:each) do
        u1 = RightScale::LoginUser.new("1234", "rs1234", "ssh-rsa aaa 1234@rightscale.com", "1234@rightscale.com", true, three_months_from_now)
        u2 = RightScale::LoginUser.new("2345", "rs2345", "ssh-rsa bbb 2345@rightscale.com", "2345@rightscale.com", true, nil)
        @policy.users << u1
        @policy.users << u2
      end


      it 'should create a timer for 1 day' do
        flexmock(EventMachine::Timer).should_receive(:new).with(approximately(86_400), Proc)
        policy = @policy
        @mgr.instance_eval {
          schedule_expiry(policy, @agent_identity).should == true
        }
      end
    end

    context 'when a user will expire in 1 hour' do
      before(:each) do
        u1 = RightScale::LoginUser.new("1234", "rs1234", "ssh-rsa aaa 1234@rightscale.com", "1234@rightscale.com", true, one_hour_from_now)
        u2 = RightScale::LoginUser.new("2345", "rs2345", "ssh-rsa bbb 2345@rightscale.com", "2345@rightscale.com", true, nil)
        @policy.users << u1
        @policy.users << u2
      end

      it 'should create a timer for 1 hour' do
        flexmock(EventMachine::Timer).should_receive(:new).with(approximately(one_hour), Proc)
        policy = @policy
        @mgr.instance_eval {
          schedule_expiry(policy, @agent_identity).should == true
        }
      end

      context 'and a user will expire in 15 minutes' do
        before(:each) do
          u3 = RightScale::LoginUser.new("1234", "rs1234", "ssh-rsa aaa 1234@rightscale.com", "1234@rightscale.com", true, minutes_from_now(15))
          @policy.users << u3
        end

        it 'should create a timer for 15 minutes' do
          flexmock(EventMachine::Timer).should_receive(:new).with(approximately(minutes(15)), Proc)
          policy = @policy
          @mgr.instance_eval {
            schedule_expiry(policy, @agent_identity).should == true
          }
        end
      end
    end
  end
  
  describe "#modify_keys_to_use_individual_profiles" do
    before(:each) do
      public_key    = "ssh-rsa aaa 1234@rightscale.com"
      uid           = "1234"
      profile_data  = "test"
      @user         = RightScale::LoginUser.new(uid, "rs#{uid}", public_key, "#{uid}@rightscale.com", true, nil, [public_key], profile_data)
    end
    context "given profile data" do
      it 'should return a user\'s profile in the command string' do
        user = @user
        @mgr.instance_eval {
          keys = modify_keys_to_use_individual_profiles([user])
          keys.kind_of?(Array).should == true
          keys.size.should == 1
          keys.first.include?('--profile').should == true
        }
        
        # @User: #<RightScale::LoginUser:0x103622ad8 @common_name="1234@rightscale.com", @public_key="ssh-rsa aaa 1234@rightscale.com", @profile_data="test", @username="rs1234", @uuid="1234", @public_keys=["ssh-rsa aaa 1234@rightscale.com"], @superuser=true>
        # ["command=\"rs_thunk --username rs1234 --email 1234@rightscale.com --profile test\"  ssh-rsa aaa 1234@rightscale.com"]
      end
    end
  end
  
  describe "#get_key_prefix" do
    before(:each) do
      @username      = "123"
      @email         = "#{@username}@rightscale.com"
      @uuid          = @username.to_i
      @profile_data  = "test"
    end
    context "given username, email and uuid" do
      it "should return a rs_thunk command line with proper formatting" do
         key_prefix = @mgr.get_key_prefix(@username, @email, @uuid, false)
         key_prefix.should include('--username')
         key_prefix.should include('--email')
         key_prefix.should include('--uuid')
         key_prefix.should_not include('--superuser')
      end
    end
    context "given a superuser value of true" do
      it "should return a rs_thunk command line with proper formatting" do
        
        @mgr.get_key_prefix(@username, @email, @uuid, true).should include('--superuser')
      end
    end
    context "given a superuser value of false" do
      it "should return a rs_thunk command line with proper formatting" do
        
        @mgr.get_key_prefix(@username, @email, @uuid, false).should_not include('--superuser')
      end
    end
    context "given a profile" do
      it "should return a rs_thunk command line with proper formatting" do
        
        @mgr.get_key_prefix(@username, @email, @uuid, false, @profile_data).should include('--profile')
      end
    end
  end
end
