#--
# Copyright (c) SolarWinds, LLC.
# All rights reserved.
#++

module AppOpticsAPM
  module SDK

    module CurrentTraceInfo
      # Creates an instance of {TraceInfo} with instance methods {TraceInfo#trace_id},
      # {TraceInfo#span_id}, {TraceInfo#trace_flags}, {TraceInfo#for_log},
      # and {TraceInfo#hash_for_log}.
      #
      # === Example:
      #
      #   trace = AppOpticsAPM::SDK.current_trace_info
      #   trace.for_log        # 'trace_id=7435a9fe510ae4533414d425dadf4e18 span_id=49e60702469db05f trace_flags=01' or '' depends on Config
      #   trace.hash_for_log   # { trace_id: '7435a9fe510ae4533414d425dadf4e18',
      #                            span_id: '49e60702469db05f',
      #                            trace_flags: ''}  or {} depends on Config
      #
      # Configure trace info injection with lograge:
      #
      #    Lograge.custom_options = lambda do |event|
      #       AppOpticsAPM::SDK.current_trace_info.hash_for_log
      #    end
      #

      def current_trace_info
        TraceInfo.new
      end

      # @attr trace_id
      # @attr span_id
      # @attr trace_flags
      class TraceInfo
        attr_reader :tracestring, :trace_id, :span_id, :trace_flags, :do_log

        SQL_REGEX=/\/\*\s*traceparent=.*\*\/\s*/.freeze
        private_constant :SQL_REGEX

        def initialize
          tracestring = AppOpticsAPM::Context.toString
          parts = AppOpticsAPM::TraceString.split(tracestring)

          @tracestring = parts[:tracestring]
          @trace_id = parts[:trace_id]
          @span_id = parts[:span_id]
          @trace_flags = parts[:flags]

          @do_log = log? # true if the tracecontext should be added to logs
          @do_sql = sql? # true if the tracecontext should be added to sql
        end

        # for_log returns a string in the format
        # 'trace_id=<trace_id> span_id=<span_id> trace_flags=<trace_flags>' or ''.
        #
        # An empty string is returned depending on the setting for
        # <tt>AppOpticsAPM::Config[:log_traceId]</tt>, which can be :never,
        # :sampled, :traced, or :always.
        #
        def for_log
          @for_log ||= @do_log ? "trace_id=#{@trace_id} span_id=#{@span_id} trace_flags=#{@trace_flags}" : ''
        end

        def hash_for_log
          @hash_for_log ||= @do_log ? { trace_id: @trace_id,
                                       span_id: @span_id,
                                       trace_flags: @trace_flags } : {}
        end

        def for_sql
          @for_sql ||= @do_sql ? "/*traceparent='#{@tracestring}'*/" : ''
        end

        ##
        # add_traceparent_to_sql
        #
        # returns the sql with "/*traceparent='#{@trace_id}'*/" prepended
        #
        def add_traceparent_to_sql(sql)
          sql = sql.gsub(SQL_REGEX, '') # remove if it was added before
          "#{AppOpticsAPM::SDK.current_trace_info.for_sql}#{sql}"
        end

        private

        # if true the trace info should be added to the log message
        def log?
          case AppOpticsAPM::Config[:log_traceId]
          when :never, nil
            false
          when :always
            # there is no way @tracestring is not ok
            # it may be all 0s, but that is ok
            # AppOpticsAPM::TraceString.ok?(@tracestring)
            true
          when :traced
            AppOpticsAPM::TraceString.valid?(@tracestring)
          when :sampled
            AppOpticsAPM::TraceString.sampled?(@tracestring)
          end
        end

        # if true the trace info should be added to the sql query
        def sql?
           AppOpticsAPM::Config[:tag_sql] &&
             AppOpticsAPM::TraceString.sampled?(@tracestring)
        end

      end

    end

    extend CurrentTraceInfo
  end
end
