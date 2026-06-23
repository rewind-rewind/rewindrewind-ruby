# frozen_string_literal: true

module RewindRewind
  # Pure Rack middleware: captures any exception raised by the downstream app,
  # reports it to RewindRewind with request context, then re-raises so the
  # host's own error handling is untouched.
  #
  # Works with any Rack-based stack (Sinatra, Hanami, Roda, a bare rackup
  # config, ...). It has no Rails dependency — the Rails integration merely
  # auto-inserts this same class.
  #
  # @example config.ru
  #   require "rewind_rewind"
  #   RewindRewind.configure { |c| c.api_key = ENV["REWINDREWIND_PROJECT_KEY"]; c.environment = "production" }
  #   use RewindRewind::Rack
  #   run MyApp
  class Rack
    def initialize(app)
      @app = app
    end

    def call(env)
      @app.call(env)
    rescue Exception => error # rubocop:disable Lint/RescueException
      # If another path (e.g. the Rails error subscriber) already captured this
      # exact exception object, don't duplicate it — just re-raise. Otherwise
      # capture (with our request context), mark it, then re-raise.
      raise if RewindRewind.already_reported?(error)

      RewindRewind.capture_exception(error, request: request_context(env))
      RewindRewind.mark_reported!(error)
      raise
    end

    private

    # Query strings routinely carry secrets (reset tokens, session ids, API
    # keys), so we deliberately drop them from the auto-captured request: the
    # recorded url and path contain no raw query params. Callers who pass an
    # explicit `request:` to capture_exception still get it scrubbed in the
    # client, but here we never even read QUERY_STRING.
    def request_context(env)
      {
        method: env["REQUEST_METHOD"],
        path: env["PATH_INFO"],
        url: reconstruct_url(env),
        remote_ip: env["REMOTE_ADDR"],
        user_agent: env["HTTP_USER_AGENT"]
      }.compact
    end

    def reconstruct_url(env)
      scheme = env["rack.url_scheme"] || "http"
      host = env["HTTP_HOST"] || env["SERVER_NAME"]
      return nil unless host

      path = env["PATH_INFO"].to_s
      "#{scheme}://#{host}#{path}"
    end
  end
end
