# Copyright (c) 2015 AppNeta, Inc.
# All rights reserved.

if defined?(::Delayed) && TraceView::Config[:delayed_jobworker][:enabled]

  module TraceView
    module Inst
      module DelayedJob
        ##
        # ForkHandler
        #
        # Since delayed job doesn't offer a hook into `after_fork`, we alias the method
        # here to do our magic after a fork happens.
        #
        module ForkHandler
          def self.extended(klass)
            ::TraceView::Util.class_method_alias(klass, :after_fork, ::Delayed::Worker)
          end

          def after_fork_with_traceview
            ::TraceView.logger.info '[traceview/delayed_job] Detected fork.  Restarting TraceView reporter.' if TraceView::Config[:verbose]
            ::TraceView::Reporter.restart unless ENV.key?('TRACEVIEW_GEM_TEST')

            after_fork_without_traceview
          end
        end

        ##
        # TraceView::Inst::DelayedJob::Plugin
        #
        # The TraceView DelayedJob plugin.  Here we wrap `enqueue` and
        # `perform` to capture the timing of the bits we're interested
        # in.
        #
        class Plugin < Delayed::Plugin
          callbacks do |lifecycle|

            # enqueue
            lifecycle.around(:enqueue) do |job, &block|
              begin
                report_kvs = {}
                report_kvs[:Spec] = :pushq
                report_kvs[:Flavor] = :DelayedJob
                report_kvs[:JobName] = job.name
                report_kvs[:MsgID] = job.id
                report_kvs[:Queue] = job.queue if job.queue
                report_kvs['Backtrace'] = TV::API.backtrace if TV::Config[:delayed_jobclient][:collect_backtraces]

                result = TraceView::API.trace('delayed_job-client', report_kvs) do
                  block.call(job)
                end

                result
              end
            end

            # perform
            # We hook here to collect info on the worker running
            # the job
            lifecycle.before(:perform) do |job, worker, &block|
              # Apparently, we can only retrieve the worker name from
              # this hook (and not in invote_job)
              TraceView::API.log_info(nil, :WorkerName => worker.name)
              block.call(job, worker)
            end

            # invoke_job
            lifecycle.around(:invoke_job) do |job, &block|
              report_kvs = {}
              report_kvs[:Spec] = :job
              report_kvs[:Flavor] = :DelayedJob
              report_kvs[:JobName] = job.name
              report_kvs[:MsgID] = job.id
              report_kvs[:Queue] = job.queue if job.queue
              #report_kvs[:WorkerName] = worker.name
              report_kvs['Backtrace'] = TV::API.backtrace if TV::Config[:delayed_jobworker][:collect_backtraces]

              # DelayedJob Specific KVs
              report_kvs[:priority] = job.priority
              report_kvs[:attempts] = job.attempts
              report_kvs[:locked_by] = job.locked_by

              result = TraceView::API.start_trace('delayed_job-worker', nil, report_kvs) do
                block.call(job)
              end
              result[0]
            end

            lifecycle.around(:error) do |worker, job, &block|
              TV::API.log_exception(nil, job.error)
              block.call(worker, job)
            end
          end
        end
      end
    end
  end

  ::TraceView.logger.info '[traceview/loading] Instrumenting delayed_job' if TraceView::Config[:verbose]
  ::TraceView::Util.send_extend(::Delayed::Worker, ::TraceView::Inst::DelayedJob::ForkHandler)
  ::Delayed::Worker.plugins << ::TraceView::Inst::DelayedJob::Plugin
end
