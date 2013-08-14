# Copyright (c) 2012 by Tracelytics, Inc.
# All rights reserved.

require 'oboe/frameworks/rails/inst/connection_adapters/mysql'
require 'oboe/frameworks/rails/inst/connection_adapters/mysql2'
require 'oboe/frameworks/rails/inst/connection_adapters/postgresql'
require 'oboe/frameworks/rails/inst/connection_adapters/oracle'

module Oboe
  module Inst
    module ConnectionAdapters
      module Utils
        def extract_trace_details(sql, name = nil)
          opts = {}

          begin
            opts[:Query] = sql.to_s
            opts[:Name] = name.to_s if name
            opts[:Backtrace] = Oboe::API.backtrace

            if ::Rails::VERSION::MAJOR == 2
              config = ::Rails.configuration.database_configuration[::Rails.env]
            else
              config = ::Rails.application.config.database_configuration[::Rails.env]
            end  

            opts[:Database]   = config["database"] if config.has_key?("database")
            opts[:RemoteHost] = config["host"]     if config.has_key?("host")
            opts[:Flavor]     = config["adapter"]  if config.has_key?("adapter")
          rescue Exception => e
          end

          return opts || {}
        end

        # We don't want to trace framework caches.  Only instrument SQL that
        # directly hits the database.
        def ignore_payload?(name)
          %w(SCHEMA EXPLAIN CACHE).include? name.to_s or (name and name.to_sym == :skip_logging)
        end

        def cfg
          @config
        end
        
        def execute_with_oboe(sql, name = nil)
          if Oboe.tracing? and !ignore_payload?(name)

            opts = extract_trace_details(sql, name)
            Oboe::API.trace('activerecord', opts || {}) do
              execute_without_oboe(sql, name)
            end
          else
            execute_without_oboe(sql, name)
          end
        end
        
        def exec_query_with_oboe(sql, name = nil, binds = [])
          if Oboe.tracing? and !ignore_payload?(name)

            opts = extract_trace_details(sql, name)
            Oboe::API.trace('activerecord', opts || {}) do
              exec_query_without_oboe(sql, name, binds)
            end
          else
            exec_query_without_oboe(sql, name, binds)
          end
        end
        
        def exec_delete_with_oboe(sql, name = nil, binds = [])
          if Oboe.tracing? and !ignore_payload?(name)

            opts = extract_trace_details(sql, name)
            Oboe::API.trace('activerecord', opts || {}) do
              exec_delete_without_oboe(sql, name, binds)
            end
          else
            exec_delete_without_oboe(sql, name, binds)
          end
        end
        
        def exec_insert_with_oboe(sql, name = nil, binds = [])
          if Oboe.tracing? and !ignore_payload?(name)

            opts = extract_trace_details(sql, name)
            Oboe::API.trace('activerecord', opts || {}) do
              exec_insert_without_oboe(sql, name, binds)
            end
          else
            exec_insert_without_oboe(sql, name, binds)
          end
        end
        
        def begin_db_transaction_with_oboe()
          if Oboe.tracing?
            opts = {}

            opts[:Query] = "BEGIN"
            Oboe::API.trace('activerecord', opts || {}) do
              begin_db_transaction_without_oboe()
            end
          else
            begin_db_transaction_without_oboe()
          end
        end
      end # Utils
    end
  end
end

if Oboe::Config[:active_record][:enabled]
  begin
    adapter = ActiveRecord::Base::connection.adapter_name.downcase

    Oboe::Inst::ConnectionAdapters::FlavorInitializers.mysql      if adapter == "mysql"
    Oboe::Inst::ConnectionAdapters::FlavorInitializers.mysql2     if adapter == "mysql2"
    Oboe::Inst::ConnectionAdapters::FlavorInitializers.postgresql if adapter == "postgresql"
    Oboe::Inst::ConnectionAdapters::FlavorInitializers.oracle     if adapter == "oracleenhanced"

  rescue Exception => e
    Oboe.logger.error "[oboe/error] Oboe/ActiveRecord error: #{e.message}" if Oboe::Config[:verbose]
  end
end
# vim:set expandtab:tabstop=2
