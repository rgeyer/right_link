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

module RightScale

  class BundlesQueue 

    FINAL_BUNDLE = 'end'
    SHUTDOWN_BUNDLE = 'shutdown'

    # Set continuation block to be called after 'close' is called
    #
    # === Block
    # continuation block
    def initialize(&continuation)
      @queue = Queue.new
      @thread_names_to_pids = {}
      @continuation = continuation
      @active = false
    end

    # Activate queue for execution, idempotent
    # Any pending bundle will be run sequentially in order
    #
    # === Return
    # true:: Always return true
    def activate
      return if @active
      EM.defer { run }
      @active = true
    end

    # Push new context to bundle queue and run next bundle
    #
    # === Return
    # true:: Always return true
    def push(context)
      @queue << context
      true
    end

    # Run next bundle in the queue if active
    # If bundle is FINAL_BUNDLE then call continuation block and deactivate
    #
    # === Return
    # true:: Always return true
    def run
      context = @queue.shift
      if context == FINAL_BUNDLE
        EM.next_tick { @continuation.call if @continuation }
        @active = false
      elsif context == SHUTDOWN_BUNDLE
        # process shutdown request.
        ShutdownRequest.instance.process

        # continue in queue in the expectation that the decommission bundle will
        # shutdown the instance and its agent normally.
        EM.defer { run }
      elsif false == context.decommission && ShutdownRequest.instance.immediately?
        # immediate shutdown pre-empts any futher attempts to run operational
        # scripts but still allows the decommission bundle to run.
        # proceed ignoring bundles until final or shutdown are encountered.
        context.audit.update_status("Skipped bundle due to immediate shutdown: #{context.payload}")
        EM.defer { run }
      else
        # provide callbacks to manage thread access.
        # TODO implement concurrency
        pid_callback = lambda do |sequence|
          # map executable bundle thread names to an ordered array of PIDs
          # (a priority queue) such that the first PID in the queue always gets
          # access to the thread until it dies and is popped from the head.
          (@thread_names_to_pids[sequence.thread_name] ||= []) << sequence.pid
        end
        sequence = RightScale::ExecutableSequenceProxy.new(context, :pid_callback => pid_callback )
        sequence.callback { audit_status(sequence) }
        sequence.errback  { audit_status(sequence) }
        sequence.run
      end
      true
    rescue Exception => e
      Log.error(Log.format("BundlesQueue.run failed", e, :trace))
    end

    # Attempts to acquire the thread given by name for the given pid.
    #
    # === Parameters
    # thread_name(String):: thread name
    # pid(Fixnum):: cook process ID
    #
    # === Return
    # result(Boolean):: true if acquired thread, false to retry
    def acquire_thread(thread_name, pid)
      # check the priority queue and only grant the PID access if it is the
      # first PID in its swim lane.
      #
      # note that it is possible (albeit extremely unlikely) for a child cook
      # process to request access before it's PID has been recorded locally. in
      # that case it would have to retry later.
      if pids = @thread_names_to_pids[thread_name]
        return pids.first == pid
      end
      return false
    end

    # Clear queue content
    #
    # === Return
    # true:: Always return true
    def clear
      @queue.clear
      true
    end

    # Close queue so that further call to 'push' will be ignored
    #
    # === Return
    # true:: Always return true
    def close
      push(FINAL_BUNDLE)
    end

    # Audit executable sequence status after it ran
    #
    # === Parameters
    # sequence(RightScale::ExecutableSequence):: finished sequence being audited
    #
    # === Return
    # true:: Always return true
    def audit_status(sequence)
      # remove PID for finished cook process. note that it should always appear
      # at the head of the queue but for sanity remove the PID wherever it
      # appears in the list.
      Log.debug("Removing cook #{sequence.pid} from thread #{sequence.thread_name.inspect} list = #{@thread_names_to_pids[sequence.thread_name].inspect}")
      if pids = @thread_names_to_pids[sequence.thread_name]
        pids.delete(sequence.pid)
      end
      context = sequence.context
      title = context.decommission ? 'decommission ' : ''
      title += context.succeeded ? 'completed' : 'failed'
      context.audit.update_status("#{title}: #{context.payload}")
      true
    rescue Exception => e
      Log.error(Log.format("BundlesQueue.audit_status failed", e, :trace))
    ensure
      EM.defer { run }
    end

  end

end
