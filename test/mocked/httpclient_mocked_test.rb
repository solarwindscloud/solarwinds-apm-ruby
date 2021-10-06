# Copyright (c) 2016 SolarWinds, LLC.
# All rights reserved.

unless defined?(JRUBY_VERSION)
  require 'minitest_helper'
  require 'webmock/minitest'
  require 'mocha/minitest'

  require 'rack/test'
  require 'rack/lobster'
  require 'appoptics_apm/inst/rack'

  class HTTPClientMockedTest < Minitest::Test

    include Rack::Test::Methods

    def app
      @app = Rack::Builder.new {
        # use Rack::CommonLogger
        # use Rack::ShowExceptions
        use AppOpticsAPM::Rack
        map "/out" do
          run Proc.new {
            clnt = HTTPClient.new
            clnt.get('http://127.0.0.1:8101/')
            [200, {"Content-Type" => "text/html"}, ['Hello AppOpticsAPM!']]
          }
        end
      }
    end

    def setup
      AppOpticsAPM::Context.clear

      WebMock.enable!
      WebMock.reset!
      WebMock.disable_net_connect!

      @sample_rate = AppOpticsAPM::Config[:sample_rate]
      @tracing_mode = AppOpticsAPM::Config[:tracing_mode]
      @blacklist = AppOpticsAPM::Config[:blacklist]

      AppOpticsAPM::Config[:sample_rate] = 1000000
      AppOpticsAPM::Config[:tracing_mode] = :enabled
      AppOpticsAPM::Config[:blacklist] = []
    end

    def teardown
      AppOpticsAPM::Config[:sample_rate] = @sample_rate
      AppOpticsAPM::Config[:tracing_mode] = @tracing_mode
      AppOpticsAPM::Config[:blacklist] = @blacklist
    end

    #====== DO REQUEST ===================================================

    def test_do_request_tracing_sampling_array_headers
      stub_request(:get, "http://127.0.0.1:8101/")
      AppOpticsAPM::API.start_trace('httpclient_test') do
        clnt = HTTPClient.new
        clnt.get('http://127.0.0.1:8101/', nil, [['some_header', 'some_value'], ['some_header2', 'some_value2']])
      end

      assert_requested(:get, "http://127.0.0.1:8101/", times: 1) do |req|
        assert_trace_headers(req.headers, true)
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_do_request_tracing_sampling_hash_headers
      stub_request(:get, "http://127.0.0.6:8101/")
      AppOpticsAPM::API.start_trace('httpclient_test') do
        clnt = HTTPClient.new
        clnt.get('http://127.0.0.6:8101/', nil, { 'some_header' => 'some_value', 'some_header2' => 'some_value2' })
      end

      assert_requested(:get, "http://127.0.0.6:8101/", times: 1) do |req|
        assert_trace_headers(req.headers, true)
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_do_request_tracing_not_sampling
      stub_request(:get, "http://127.0.0.2:8101/")
      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config[:sample_rate] = 0
        AppOpticsAPM::API.start_trace('httpclient_test') do
          clnt = HTTPClient.new
          clnt.get('http://127.0.0.2:8101/')
        end
      end

      assert_requested(:get, "http://127.0.0.2:8101/", times: 1) do |req|
        assert_trace_headers(req.headers, false)
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_do_request_no_xtrace
      stub_request(:get, "http://127.0.0.3:8101/")
      clnt = HTTPClient.new
      clnt.get('http://127.0.0.3:8101/')

      assert_requested :get, "http://127.0.0.3:8101/", times: 1
      assert_not_requested :get, "http://127.0.0.3:8101/", headers: {'Traceparent'=>/^.*$/}
    end

    def test_do_request_blacklisted
      stub_request(:get, "http://127.0.0.4:8101/")

      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config.blacklist << '127.0.0.4'
        AppOpticsAPM::API.start_trace('httpclient_tests') do
          clnt = HTTPClient.new
          clnt.get('http://127.0.0.4:8101/')
        end
      end

      assert_requested :get, "http://127.0.0.4:8101/"
      assert_not_requested :get, "http://127.0.0.4:8101/", headers: {'Traceparent'=>/^.*$/}
      refute AppOpticsAPM::Context.isValid
    end

    def test_do_request_not_sampling_blacklisted
      stub_request(:get, "http://127.0.0.5:8101/")

      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config[:sample_rate] = 0
        AppOpticsAPM::Config.blacklist << '127.0.0.5'
        AppOpticsAPM::API.start_trace('httpclient_tests') do
          clnt = HTTPClient.new
          clnt.get('http://127.0.0.5:8101/')
        end
      end

      assert_requested :get, "http://127.0.0.5:8101/"
      assert_not_requested :get, "http://127.0.0.5:8101/", headers: {'Traceparent'=>/^.*$/}
      refute AppOpticsAPM::Context.isValid
    end

    #====== ASYNC REQUEST ================================================
    # using expectations in these tests because stubbing doesn't work with threads

    def test_async_tracing_sampling_array_headers
      WebMock.disable!

      Thread.expects(:new).yields   # continue without forking off a thread

      HTTPClient.any_instance.expects(:do_get_stream).with do |req, _, _|
        assert_equal 'http://127.0.0.11:8101/', req.header.request_uri.to_s
        assert_trace_headers(req.headers, true)
      end

      AppOpticsAPM::API.start_trace('httpclient_test') do
        clnt = HTTPClient.new
        clnt.get_async('http://127.0.0.11:8101/', nil, [['some_header', 'some_value'], ['some_header2', 'some_value2']])
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_async_tracing_sampling_hash_headers
      WebMock.disable!

      Thread.expects(:new).yields   # continue without forking off a thread

      HTTPClient.any_instance.expects(:do_get_stream).with do |req, _, _|
        assert_equal 'http://127.0.0.16:8101/', req.header.request_uri.to_s
        assert_trace_headers(req.headers, true)
      end

      AppOpticsAPM::API.start_trace('httpclient_test') do
        clnt = HTTPClient.new
        clnt.get_async('http://127.0.0.16:8101/', nil, { 'some_header' => 'some_value', 'some_header2' => 'some_value2' })
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_async_tracing_not_sampling
      WebMock.disable!

      Thread.expects(:new).yields   # continue without forking off a thread

      HTTPClient.any_instance.expects(:do_get_stream).with do |req, _, _|
        assert_equal 'http://127.0.0.12:8101/', req.header.request_uri.to_s
        assert_trace_headers(req.headers, false)
      end

      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config[:sample_rate] = 0
        AppOpticsAPM::API.start_trace('httpclient_test') do
          clnt = HTTPClient.new
          clnt.get_async('http://127.0.0.12:8101/')
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_async_no_xtrace
      WebMock.disable!

      Thread.expects(:new).yields   # continue without forking off a thread

      HTTPClient.any_instance.expects(:do_get_stream).with do |req, _, _|
        assert_equal 'http://127.0.0.13:8101/', req.header.request_uri.to_s
        assert req.header['Traceparent'].empty?
      end

      clnt = HTTPClient.new
      clnt.get_async('http://127.0.0.13:8101/')
    end

    def test_async_blacklisted
      WebMock.disable!

      Thread.expects(:new).yields   # continue without forking off a thread

      HTTPClient.any_instance.expects(:do_get_stream).with do |req, _, _|
        assert_equal 'http://127.0.0.14:8101/', req.header.request_uri.to_s
        assert req.header['Traceparent'].empty?
      end

      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config.blacklist << '127.0.0.14'
        AppOpticsAPM::API.start_trace('httpclient_tests') do
          clnt = HTTPClient.new
          clnt.get_async('http://127.0.0.14:8101/')
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_async_not_sampling_blacklisted
      WebMock.disable!

      Thread.expects(:new).yields   # continue without forking off a thread

      HTTPClient.any_instance.expects(:do_get_stream).with do |req, _, _|
        assert_equal 'http://127.0.0.15:8101/', req.header.request_uri.to_s
        assert req.header['Traceparent'].empty?
      end

      AppOpticsAPM.config_lock.synchronize do
        AppOpticsAPM::Config[:sample_rate] = 0
        AppOpticsAPM::Config.blacklist << '127.0.0.15'
        AppOpticsAPM::API.start_trace('httpclient_tests') do
          clnt = HTTPClient.new
          clnt.get_async('http://127.0.0.15:8101/')
        end
      end
      refute AppOpticsAPM::Context.isValid
    end

    # ========== make sure headers are preserved =============================
    def test_preserves_custom_headers
      stub_request(:get, "http://127.0.0.6:8101/").to_return(status: 200, body: "", headers: {})

      AppOpticsAPM::API.start_trace('httpclient_tests') do
        clnt = HTTPClient.new
        clnt.get('http://127.0.0.6:8101/', nil, [['Custom', 'specialvalue'], ['some_header2', 'some_value2']])
      end

      assert_requested :get, "http://127.0.0.6:8101/", headers: {'Custom'=>'specialvalue'}, times: 1
      refute AppOpticsAPM::Context.isValid
    end

    def test_async_preserves_custom_headers
      WebMock.disable!

      Thread.expects(:new).yields   # continue without forking off a thread

      HTTPClient.any_instance.expects(:do_get_stream).with do |req, _, _|
        assert req.headers['Custom'], "Custom header missing"
        assert_match(/^specialvalue$/, req.headers['Custom'] )
      end

      AppOpticsAPM::API.start_trace('httpclient_tests') do
        clnt = HTTPClient.new
        clnt.get_async('http://127.0.0.6:8101/', nil, [['Custom', 'specialvalue'], ['some_header2', 'some_value2']])
      end
      refute AppOpticsAPM::Context.isValid
    end

    ##### W3C tracestate propagation

    def test_propagation_simple_trace_state
      stub_request(:get, "http://127.0.0.1:8101/").to_return(status: 200, body: "propagate", headers: {})

      task_id = 'a462ade6cfe479081764cc476aa9831b'
      trace_id = "00-#{task_id}-cb3468da6f06eefc-01"
      state = 'sw=cb3468da6f06eefc01'
      get "/out", {}, { 'HTTP_TRACEPARENT' => trace_id,
                        'HTTP_TRACESTATE'  => state }

      assert_requested(:get, "http://127.0.0.1:8101/", times: 1) do |req|
        assert_trace_headers(req.headers, true)
        assert_equal task_id, AppOpticsAPM::TraceParent.task_id(req.headers['Traceparent'])
      end
      refute AppOpticsAPM::Context.isValid
    end

    def test_propagation_multimember_trace_state
      stub_request(:get, "http://127.0.0.1:8101/").to_return(status: 200, body: "propagate", headers: {})

      task_id = 'a462ade6cfe479081764cc476aa9831b'
      trace_id = "00-#{task_id}-cb3468da6f06eefc-01"
      state = 'aa= 1234, sw=cb3468da6f06eefc01,%%cc=%%%45'
      get "/out", {}, { 'HTTP_TRACEPARENT' => trace_id,
                        'HTTP_TRACESTATE'  => state }

      assert_requested(:get, "http://127.0.0.1:8101/", times: 1) do |req|
        assert_trace_headers(req.headers, true)
        assert_equal task_id, AppOpticsAPM::TraceParent.task_id(req.headers['Traceparent'])
        assert_equal "sw=#{AppOpticsAPM::TraceParent.edge_id_flags(req.headers['Traceparent'])},aa= 1234",
                     req.headers['Tracestate']

      end
      refute AppOpticsAPM::Context.isValid
    end

  end
end
