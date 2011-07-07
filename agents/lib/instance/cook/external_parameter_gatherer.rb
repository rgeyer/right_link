#
# Copyright (c) 2011 RightScale Inc
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

require 'singleton'

module RightScale

  # Provides access to RightLink agent audit methods
  class ExternalParameterGatherer
    include EM::Deferrable

    # Initialize command protocol
    #
    # === Parameters
    # bundle<RightScale::ExecutableBundle>:: the bundle for which to gather inputs
    # options[:listen_port]:: Command server listen port
    # options[:cookie]:: Command protocol cookie
    #
    # === Return
    # true:: Always return true
    def initialize(executables, options)
      @executables_inputs = {}

      cmd_callback = Proc.new do |data|
        #TODO substitute parameters
        File.open('/tmp/tony', 'a') { |f| f.puts data  }
        #TODO check done-ness
        succeed(@executables_inputs) if done?
      end

      @agent_connection = EM.connect('127.0.0.1', options[:listen_port], AgentConnection, options[:cookie], cmd_callback)

      executables.each do |exe|
        case exe
          when RightScale::RecipeInstantiation
            externals = exe.external_attributes
          when RightScale::RightScriptInstantiation
            externals = exe.external_parameters
          else
            raise ArgumentError, "Can't process external parameters for a #{exe.class.name}"
        end
        next if externals.nil? || externals.empty?

        @executables_inputs[exe] = externals
      end
    end

    #TODO docs
    def run
      @executables_inputs.each_pair do |exe, locations|
        locations.each do |location|
          cmd = {:name => :send_retryable_request,
                 :type => '/vault/get',
                 :payload => {},
                 :options => {}}
          EM.next_tick { @agent_connection.send_command(cmd) }
        end
      end
    end

    def done?
      @executables_inputs.values.all? { |ary| ary.all? { |p| p.is_a?(RightScale::CredentialValue) } }
    end

    protected

    # Stop command client, wait for all pending commands to finish
    def stop
      if @agent_connection
        # allow any pending responses to be processed
        # by placing stop on the end of the next_tick queue.
        EM.next_tick { @agent_connection.stop { fail } }
      else
        fail
      end
    end

  end

end
