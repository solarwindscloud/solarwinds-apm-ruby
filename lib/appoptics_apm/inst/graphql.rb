# frozen_string_literal: true

#--
# Copyright (c) 2019 SolarWinds, LLC.
# All rights reserved.
#++

# initial version of this instrumentation:
# https://github.com/librato/api/blob/master/graph/tracing/appoptics.rb
#

# TODO: make sure this stays up to date with
# ____  what is in the graphql gem and vice-versa

if defined?(GraphQL::Tracing)
  module GraphQL
    module Tracing
      # AppOpticsTracing in the graphql gem may be a different version than the
      # one defined here, we want to use the newer one
      dont_redefine = false
      this_version = Gem::Version.new('1.0.0')

      if defined?(GraphQL::Tracing::AppOpticsTracing)
        if this_version > GraphQL::Tracing::AppOpticsTracing::VERSION
          send(:remove_const, :AppOpticsTracing)
        else
          dont_redefine = true
        end
      end

      unless dont_redefine
        #-----------------------------------------------------------------------------#
        #----- this class is duplicated in the graphql gem ---------------------------#
        #-----------------------------------------------------------------------------#
        class AppOpticsTracing < GraphQL::Tracing::PlatformTracing
          # These GraphQL events will show up as 'graphql.prep' spans
          PREP_KEYS = ['lex', 'parse', 'validate', 'analyze_query', 'analyze_multiplex'].freeze

          # During auto-instrumentation this version of AppOpticsTracing is compared
          # with the version provided in the graphql gem, so that the newer
          # version of the class can be used
          VERSION = Gem::Version.new('1.0.0').freeze

          self.platform_keys = {
            'lex' => 'lex',
            'parse' => 'parse',
            'validate' => 'validate',
            'analyze_query' => 'analyze_query',
            'analyze_multiplex' => 'analyze_multiplex',
            'execute_multiplex' => 'execute_multiplex',
            'execute_query' => 'execute_query',
            'execute_query_lazy' => 'execute_query_lazy'
          }

          def platform_trace(platform_key, _key, data)
            return yield if !defined?(AppOpticsAPM) || gql_config[:enabled] == false

            kvs = metadata(data)
            kvs[:Key] = platform_key if PREP_KEYS.include?(platform_key)

            maybe_set_transaction_name(kvs[:InboundQuery]) if kvs[:InboundQuery]

            ::AppOpticsAPM::SDK.trace(span_name(platform_key), kvs) do
              kvs.clear # we don't have to send them twice
              result = yield
              report_errors(result)
              result
            end
          end

          def platform_field_key(type, field)
            "graphql.#{type.name}.#{field.name}"
          end

          private

          def gql_config
            ::AppOpticsAPM::Config[:graphql] ||= {}
          end

          ###
          # any errors graphql has dealt with are added to the response
          def report_errors(result)
            return unless result.is_a?(Array)

            result.each do |res|
              if res.is_a?(GraphQL::Query::Result) && res.to_h['errors']
                msg = res.to_h['errors'].map { |r| r['message'] }.join("\n")
                AppOpticsAPM::SDK.log_info(Message: "GraphQL Errors:\n#{msg}")
              end
            end
          end

          def maybe_set_transaction_name(query)
            return if gql_config[:transaction_name] == false ||
                      ::AppOpticsAPM::SDK.get_transaction_name

            split_query = query.strip.split(/\W+/, 3)
            name = "graphql.#{split_query[0..1].join('.')}"
            ::AppOpticsAPM::SDK.set_transaction_name(name)
          end

          def span_name(key)
            return 'graphql.prep' if PREP_KEYS.include?(key)
            return key if key[/^graphql\./]

            "graphql.#{key}"
          end

          # rubocop:disable Metrics/AbcSize, Metrics/MethodLength
          def metadata(data)
            data.keys.map do |key|
              case key
              when :context
                graphql_context(data[key])
              when :query
                graphql_query(data[key])
              when :query_string
                graphql_query_string(data[key])
              when :multiplex
                graphql_multiplex(data[key])
              else
                [key, data[key]]
              end
            end.flatten.each_slice(2).to_h.merge(Spec: 'graphql')
          end
          # rubocop:enable Metrics/AbcSize, Metrics/MethodLength

          def graphql_context(context)
            res = [[:Path, context.path.join('.')]]
            return res if context.errors.empty?

            res << [:Errors, context.errors.join("\n")]
          end

          def graphql_query(query)
            query_string = query.query_string
            query_string = remove_comments(query_string) if gql_config[:remove_comments] != false
            query_string = sanitize(query_string) if gql_config[:sanitize_query] != false

            [[:InboundQuery, query_string],
             [:Operation, query.selected_operation_name]]
          end

          def graphql_query_string(query_string)
            query_string = remove_comments(query_string) if gql_config[:remove_comments] != false
            query_string = sanitize(query_string) if gql_config[:sanitize_query] != false

            [:InboundQuery, query_string]
          end

          def graphql_multiplex(data)
            names = data.queries.map(&:selected_operation_name).compact.join(', ')

            [:Operations, names]
          end

          def sanitize(query)
            # remove arguments
            query.gsub(/"[^"]*"/, '"?"')                 # strings
                 .gsub(/-?[0-9]*\.?[0-9]+e?[0-9]*/, '?') # ints + floats
                 .gsub(/\[[^\]]*\]/, '[?]')              # arrays
          end

          def remove_comments(query)
            query.gsub(/#[^\n\r]*/, '')
          end
        end
        #-----------------------------------------------------------------------------#
      end
    end
  end

  module AppOpticsAPM
    module GraphQLPrepend
      def use(plugin, options = {})
        super unless GraphQL::Schema.plugins.find { |pl| pl[0].to_s == plugin.to_s }

        GraphQL::Schema.plugins
      end
    end
  end

  if defined?(GraphQL::Schema)
    GraphQL::Schema.singleton_class.prepend(AppOpticsAPM::GraphQLPrepend)
    GraphQL::Schema.use(GraphQL::Tracing::AppOpticsTracing)
  end
end
