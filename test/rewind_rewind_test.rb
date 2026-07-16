# frozen_string_literal: true

$LOAD_PATH.unshift(File.expand_path("../lib", __dir__))

require "json"
require "minitest/autorun"
require "socket"
require "rewind_rewind"

class RewindRewindTest < Minitest::Test
  def teardown
    RewindRewind.reset!
  end

  # --- Backtrace / in_app detection -----------------------------------------

  def test_in_app_detection_app_vs_gem_vs_stdlib
    config = RewindRewind::Configuration.new
    config.project_root = "/srv/app"

    backtrace = [
      "/srv/app/lib/worker.rb:10:in 'Worker#run'",
      "/srv/app/vendor/bundle/ruby/3.4.0/gems/foo-1.0/lib/foo.rb:3:in 'Foo.bar'",
      "/usr/lib/ruby/3.4.0/net/http.rb:1600:in 'start'",
      "smoke.rb:5:in '<main>'"
    ]
    frames = RewindRewind::Backtrace.parse(backtrace, config)

    assert_equal true, frames[0][:in_app], "app frame should be in_app"
    assert_equal "Worker", frames[0][:module]
    assert_equal 10, frames[0][:line]
    assert_equal false, frames[1][:in_app], "vendored gem frame must not be in_app"
    assert_equal false, frames[2][:in_app], "stdlib frame must not be in_app"
  end

  def test_first_in_app_frame_resolves_culprit
    config = RewindRewind::Configuration.new
    config.project_root = "/srv/app"
    backtrace = [
      "/usr/lib/ruby/3.4.0/json.rb:1:in 'generate'",
      "/srv/app/app.rb:42:in 'render'"
    ]
    frames = RewindRewind::Backtrace.parse(backtrace, config)
    first_in_app = frames.find { |f| f[:in_app] }

    assert_equal "/srv/app/app.rb", first_in_app[:filename]
    assert_equal "render", first_in_app[:function]
  end

  def test_relative_app_path_is_in_app
    config = RewindRewind::Configuration.new
    config.project_root = Dir.pwd
    frame = RewindRewind::Backtrace.frame_for("smoke.rb:5:in '<main>'", config.project_root)

    assert_equal true, frame[:in_app]
  end

  # --- capture_exception payload --------------------------------------------

  def test_capture_exception_payload
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "rrpub_secret"
        c.endpoint = endpoint
        c.environment = "production"
        c.release = "ruby@1.2.3"
        c.tags = { service: "worker" }
        c.project_root = File.expand_path("..", __dir__)
      end

      begin
        raise "boom with a real backtrace"
      rescue StandardError => e
        assert_equal true, RewindRewind.capture_exception(
          e, extra: { queue: "critical" }, identity: { id: "u1", email: "u@x.com" }
        )
      end

      req = requests[0]
      assert_equal "/v1/exceptions", req[:path]
      assert_equal "Bearer rrpub_secret", req[:headers]["authorization"]
      assert_equal "application/json", req[:headers]["content-type"]

      body = req[:body]
      assert_equal "ruby", body["platform"]
      assert_equal "error", body["level"]
      assert_equal "production", body["environment"]
      assert_equal "boom with a real backtrace", body["message"]
      assert_equal "RuntimeError", body["exception"]["type"]
      assert_equal({ "queue" => "critical" }, body["extra"])
      assert_equal({ "service" => "worker" }, body["tags"])
      assert_equal({ "id" => "u1", "email" => "u@x.com" }, body["identity"])
      assert body["timestamp"].is_a?(Integer)

      top = body["exception"]["stacktrace"].first
      assert top["filename"].include?("rewind_rewind_test.rb")
      assert top["line"] > 0
      assert_equal true, top["in_app"]
    end
  end

  def test_capture_event_payload
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "rrpub_secret"
        c.endpoint = endpoint
        c.environment = "production"
        c.tags = { service: "worker" }
      end

      assert_equal true, RewindRewind.capture_event(
        "job.finished", properties: { duration_ms: 123 }, identity_id: "u1", source: "backend"
      )

      body = requests[0][:body]
      assert_equal "/v1/events", requests[0][:path]
      assert_equal "job.finished", body["type"]
      assert_equal "production", body["environment"]
      assert_equal "u1", body["identity_id"]
      assert_equal "backend", body["source"]
      assert_equal({ "duration_ms" => 123, "service" => "worker" }, body["properties"])
    end
  end

  # --- safety / no-op behaviour ---------------------------------------------

  def test_unconfigured_is_safe_noop
    refute RewindRewind.configured?
    assert_equal false, RewindRewind.capture_exception(RuntimeError.new("x"))
    assert_equal false, RewindRewind.capture_event("x")
  end

  def test_missing_api_key_disables_client
    RewindRewind.configure { |c| c.api_key = nil; c.environment = "production" }
    refute RewindRewind.configured?
  end

  def test_missing_environment_disables_client
    RewindRewind.configure { |c| c.api_key = "k"; c.environment = nil }
    refute RewindRewind.configured?
  end

  def test_capture_never_raises_on_transport_failure
    RewindRewind.configure do |c|
      c.api_key = "k"
      c.environment = "production"
      c.endpoint = "http://127.0.0.1:1" # nothing listening
      c.timeout = 0.2
    end
    assert_equal false, RewindRewind.capture_exception(RuntimeError.new("x"))
  end

  def test_rack_middleware_reports_and_reraises
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
      end

      app = ->(_env) { raise ArgumentError, "Bad route" }
      middleware = RewindRewind::Rack.new(app)

      assert_raises(ArgumentError) do
        middleware.call(
          "REQUEST_METHOD" => "POST", "PATH_INFO" => "/submit",
          "rack.url_scheme" => "https", "HTTP_HOST" => "example.com"
        )
      end

      body = requests[0][:body]
      assert_equal "Bad route", body["message"]
      assert_equal "POST", body["request"]["method"]
      assert_equal "/submit", body["request"]["path"]
      assert_equal "https://example.com/submit", body["request"]["url"]
    end
  end

  # --- per-exception idempotency guard (double-capture fix) -----------------

  def test_mark_reported_dedupes_same_exception_object
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
      end

      error = RuntimeError.new("boom")
      refute RewindRewind.already_reported?(error)

      # First capture goes through and marks the object.
      assert_equal true, RewindRewind.capture_exception(error)
      RewindRewind.mark_reported!(error)
      assert RewindRewind.already_reported?(error)

      # A second path that respects the guard must skip the same object.
      skip_second = RewindRewind.already_reported?(error)
      RewindRewind.capture_exception(error) unless skip_second

      assert_equal 1, requests.length, "same exception object must send exactly one payload"
    end
  end

  def test_two_different_exceptions_both_send
    with_server(2) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
      end

      [RuntimeError.new("one"), RuntimeError.new("two")].each do |error|
        next if RewindRewind.already_reported?(error)

        RewindRewind.capture_exception(error)
        RewindRewind.mark_reported!(error)
      end

      assert_equal 2, requests.length, "two distinct exception objects must each send"
    end
  end

  def test_guard_helpers_never_raise_on_frozen_or_odd_objects
    frozen = RuntimeError.new("frozen").freeze
    # Must not raise even when the object rejects ivar mutation.
    assert_nil RewindRewind.mark_reported!(frozen)
    assert_equal false, RewindRewind.already_reported?(frozen),
                 "frozen object could not be marked, so reports as not-reported"

    # Defensive against non-exception / odd inputs.
    assert_nil RewindRewind.mark_reported!(nil)
    assert_equal false, RewindRewind.already_reported?(nil)
  end

  # --- query-string stripping (fix 2) ---------------------------------------

  def test_rack_drops_query_string_from_request_context
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
      end

      app = ->(_env) { raise ArgumentError, "Bad route" }
      middleware = RewindRewind::Rack.new(app)

      assert_raises(ArgumentError) do
        middleware.call(
          "REQUEST_METHOD" => "GET", "PATH_INFO" => "/reset",
          "QUERY_STRING" => "reset_token=supersecret&foo=bar",
          "rack.url_scheme" => "https", "HTTP_HOST" => "example.com"
        )
      end

      request = requests[0][:body]["request"]
      assert_equal "/reset", request["path"]
      assert_equal "https://example.com/reset", request["url"]
      refute_includes request["url"], "supersecret"
      refute_includes request["url"], "?"
      refute request.key?("query_string"), "query_string must not be captured"
    end
  end

  # --- sensitive-data scrubbing (fix 1) -------------------------------------

  def test_scrubs_sensitive_keys_in_extra_tags_user_request
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
      end

      RewindRewind.capture_exception(
        RuntimeError.new("x"),
        extra: {
          password: "hunter2",
          api_key: "rrpub_leak",
          nested: { authorization: "Bearer abc", note: "keep" },
          items: [{ credit_card: "4111", label: "ok" }]
        },
        tags: { secret_token: "t", region: "us-east" },
        identity: { id: "u1", email: "u@x.com", session: "sess-123" },
        request: { method: "GET", path: "/x", cookie: "sid=abc" }
      )

      body = requests[0][:body]
      assert_equal "[FILTERED]", body["extra"]["password"]
      assert_equal "[FILTERED]", body["extra"]["api_key"]
      assert_equal "[FILTERED]", body["extra"]["nested"]["authorization"]
      assert_equal "keep", body["extra"]["nested"]["note"]
      assert_equal "[FILTERED]", body["extra"]["items"][0]["credit_card"]
      assert_equal "ok", body["extra"]["items"][0]["label"]
      assert_equal "[FILTERED]", body["tags"]["secret_token"]
      assert_equal "us-east", body["tags"]["region"]
      # identity[:id]/email are intentional attribution and must survive.
      assert_equal "u1", body["identity"]["id"]
      assert_equal "u@x.com", body["identity"]["email"]
      assert_equal "[FILTERED]", body["identity"]["session"]
      assert_equal "[FILTERED]", body["request"]["cookie"]
      assert_equal "/x", body["request"]["path"]
    end
  end

  def test_scrubs_sensitive_keys_in_event_properties
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
      end

      RewindRewind.capture_event(
        "signup", properties: { plan: "pro", access_key: "AKIA", cvv: "123" }
      )

      props = requests[0][:body]["properties"]
      assert_equal "pro", props["plan"]
      assert_equal "[FILTERED]", props["access_key"]
      assert_equal "[FILTERED]", props["cvv"]
    end
  end

  def test_sensitive_fields_is_configurable_and_disableable
    with_server(2) do |endpoint, requests|
      # Custom regexp extends the denylist.
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
        c.sensitive_fields = /custom_field/i
      end
      RewindRewind.capture_event("e", properties: { custom_field: "x", password: "p" })
      props = requests[0][:body]["properties"]
      assert_equal "[FILTERED]", props["custom_field"]
      assert_equal "p", props["password"], "non-matching key passes when overridden"

      # nil disables scrubbing entirely.
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
        c.sensitive_fields = nil
      end
      RewindRewind.capture_event("e", properties: { password: "p" })
      assert_equal "p", requests[1][:body]["properties"]["password"]
    end
  end

  # --- excluded exceptions (default denylist) -------------------------------

  # Stub the framework class names the default denylist matches, without
  # pulling in Rails/Rack. Defining them as real constants lets us raise/rescue
  # actual instances and exercise the ancestry walk.
  module ActionController
    class BadRequest < StandardError; end
  end
  class SubclassOfBadRequest < ActionController::BadRequest; end

  def test_excluded_exception_is_not_sent
    with_server(0) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
        c.excluded_exceptions = ["RewindRewindTest::ActionController::BadRequest"]
      end

      error = ActionController::BadRequest.new("Invalid request parameters")
      assert_equal false, RewindRewind.capture_exception(error),
                   "excluded exception must be dropped (returns false)"
      assert_equal 0, requests.length, "excluded exception must send zero payloads"
    end
  end

  def test_nothing_excluded_by_default
    # Boundary: the SDK never silently drops a potentially-actionable exception.
    # The default list is empty; the framework-4xx denylist is opt-in.
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
      end

      assert_empty RewindRewind::Configuration::DEFAULT_EXCLUDED_EXCEPTIONS
      assert_equal true, RewindRewind.capture_exception(
        ActionController::BadRequest.new("captured by default, not silently dropped")
      )
      assert_equal 1, requests.length
    end
  end

  def test_suggested_denylist_excludes_when_opted_in
    with_server(0) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
        # Opt into the suggested template, plus point a stub at it so the
        # name-based match fires against our local ActionController::BadRequest.
        c.excluded_exceptions =
          RewindRewind::Configuration::SUGGESTED_EXCLUDED_EXCEPTIONS +
          ["RewindRewindTest::ActionController::BadRequest"]
      end

      assert_equal false, RewindRewind.capture_exception(
        ActionController::BadRequest.new("Rack::Multipart::EmptyContentError")
      )
      assert_equal 0, requests.length
    end
  end

  def test_subclass_of_excluded_is_excluded
    with_server(0) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
        c.excluded_exceptions = ["RewindRewindTest::ActionController::BadRequest"]
      end

      assert_equal false, RewindRewind.capture_exception(
        SubclassOfBadRequest.new("subclass should be excluded too")
      )
      assert_equal 0, requests.length
    end
  end

  def test_excluded_via_cause_chain
    with_server(0) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
        c.excluded_exceptions = ["RewindRewindTest::ActionController::BadRequest"]
      end

      wrapped =
        begin
          begin
            raise ActionController::BadRequest, "root multipart error"
          rescue ActionController::BadRequest
            raise RuntimeError, "wrapper around an excluded cause"
          end
        rescue RuntimeError => e
          e
        end

      assert_equal false, RewindRewind.capture_exception(wrapped),
                   "exception whose cause is excluded must also be dropped"
      assert_equal 0, requests.length
    end
  end

  def test_normal_exception_is_sent
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
        c.excluded_exceptions = ["RewindRewindTest::ActionController::BadRequest"]
      end

      assert_equal true, RewindRewind.capture_exception(RuntimeError.new("real bug")),
                   "non-excluded exception must still be sent"
      assert_equal 1, requests.length
      assert_equal "real bug", requests[0][:body]["message"]
    end
  end

  def test_host_customized_excluded_list_is_honored
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
        # Host replaces the default list with a single custom entry.
        c.excluded_exceptions = ["ArgumentError"]
      end

      # ArgumentError is now excluded...
      assert_equal false, RewindRewind.capture_exception(ArgumentError.new("noise"))
      # ...but a default-list class is no longer excluded (list was replaced).
      assert_equal true, RewindRewind.capture_exception(
        ActionController::BadRequest.new("now sent because list was replaced")
      )
      assert_equal 1, requests.length
    end
  end

  def test_empty_excluded_list_disables_exclusion
    with_server(1) do |endpoint, requests|
      RewindRewind.configure do |c|
        c.api_key = "k"
        c.endpoint = endpoint
        c.environment = "production"
        c.excluded_exceptions = []
      end

      assert_equal true, RewindRewind.capture_exception(
        ActionController::BadRequest.new("not excluded when list is empty")
      )
      assert_equal 1, requests.length
    end
  end

  # --- endpoint validation (fix 3) ------------------------------------------

  def test_endpoint_allows_https_and_localhost_http
    %w[
      https://rewindrewind.com
      https://ingest.example.com/v1
      http://localhost:3000
      http://127.0.0.1:9292
      http://[::1]:8080
    ].each do |url|
      config = RewindRewind::Configuration.new
      config.endpoint = url
      assert_equal url, config.endpoint
    end
  end

  def test_endpoint_rejects_cleartext_remote_and_bad_schemes
    config = RewindRewind::Configuration.new
    assert_raises(ArgumentError) { config.endpoint = "http://evil.example.com" }
    assert_raises(ArgumentError) { config.endpoint = "ftp://rewindrewind.com" }
    assert_raises(ArgumentError) { config.endpoint = "rewindrewind.com" }
  end

  private

  def with_server(expected_requests)
    server = TCPServer.new("127.0.0.1", 0)
    requests = []
    endpoint = "http://127.0.0.1:#{server.addr[1]}"
    thread = Thread.new do
      expected_requests.times do
        socket = server.accept
        begin
          request_line = socket.gets
          _method, path, = request_line.split(" ")
          headers = read_headers(socket)
          body = socket.read(headers.fetch("content-length", "0").to_i)
          requests << { path: path, headers: headers, body: JSON.parse(body) }
          socket.write("HTTP/1.1 202 Accepted\r\nContent-Length: 9\r\nConnection: close\r\n\r\n{\"ok\":true}")
        ensure
          socket.close
        end
      end
    end

    yield endpoint, requests
  ensure
    thread.join if thread
    server.close if server
  end

  def read_headers(socket)
    headers = {}
    while (line = socket.gets)
      stripped = line.strip
      break if stripped.empty?

      key, value = stripped.split(":", 2)
      headers[key.downcase] = value.strip
    end
    headers
  end
end
