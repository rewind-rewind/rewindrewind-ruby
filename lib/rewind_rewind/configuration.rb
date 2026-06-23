# frozen_string_literal: true

require "uri"

module RewindRewind
  # Holds all tunable settings for a {RewindRewind::Client}.
  #
  # Defaults are read from the environment so that the gem works with zero
  # boilerplate in a containerised deploy, while still letting host apps
  # override anything explicitly via {RewindRewind.configure}.
  class Configuration
    DEFAULT_ENDPOINT = "https://rewindrewind.com"
    DEFAULT_TIMEOUT  = 2.0
    MAX_ENVIRONMENT_LENGTH = 64

    # Default denylist for sensitive-data scrubbing. Any hash value whose KEY
    # matches this (case-insensitively) is redacted before serialisation. Hosts
    # can extend or override this via {#sensitive_fields=}, or set it to nil to
    # disable scrubbing entirely.
    DEFAULT_SENSITIVE_FIELDS = /
      password|passwd|secret|token|authorization|auth|api[-_]?key|
      access[-_]?key|client[-_]?secret|cookie|session|credential|card|cvv|
      ssn|private[-_]?key
    /xi

    # Default denylist of exception class NAMES that are dropped before capture.
    # These are common non-actionable framework errors — almost always triggered
    # by malformed/hostile client requests (bots sending junk, 4xx routing/parse
    # failures) rather than bugs in the host application — so reporting them is
    # pure noise. Mirrors sentry-ruby's `excluded_exceptions` default, plus the
    # Rack multipart parse error that motivated this list.
    #
    # Stored as plain strings (NOT constant references) on purpose: the core gem
    # must not require Rails or Rack to be loaded, and these classes may not be
    # defined in a given process. Matching is done by fully-qualified class name.
    #
    # Hosts can REPLACE this list (`config.excluded_exceptions = [...]`) or APPEND
    # to it (`config.excluded_exceptions += [...]`) via {#excluded_exceptions=}.
    DEFAULT_EXCLUDED_EXCEPTIONS = [
      "ActionController::BadRequest",
      "ActionController::RoutingError",
      "ActionController::UnknownFormat",
      "ActionController::UnknownHttpMethod",
      "ActionController::InvalidAuthenticityToken",
      "ActionController::InvalidCrossOriginRequest",
      "ActionController::ParameterMissing",
      "ActionController::MethodNotAllowed",
      "ActionController::NotImplemented",
      "ActionDispatch::Http::MimeNegotiation::InvalidType",
      "ActionDispatch::Http::Parameters::ParseError",
      "Rack::Multipart::EmptyContentError",
      "Rack::QueryParser::ParameterTypeError",
      "Rack::QueryParser::InvalidParameterError",
      "ActiveRecord::RecordNotFound",
      "Sinatra::NotFound"
    ].freeze

    # Hosts that may legitimately be addressed over plain http (the project key
    # never leaves the machine, so cleartext is acceptable for local dev).
    LOCALHOST_HOSTS = ["localhost", "127.0.0.1", "::1", "[::1]"].freeze

    # @return [String, nil] project key sent as `Authorization: Bearer <key>`.
    attr_accessor :api_key

    # @return [String] base URL, without a trailing slash.
    attr_reader :endpoint

    # @return [String] deploy environment (REQUIRED by the wire protocol).
    attr_accessor :environment

    # @return [String, nil] release identifier (e.g. a git SHA or version).
    attr_accessor :release

    # @return [Hash] tags merged into every captured payload.
    attr_accessor :tags

    # @return [Float] open/read timeout in seconds for transport requests.
    attr_accessor :timeout

    # @return [Boolean] master switch; when false nothing is sent.
    attr_accessor :enabled

    # @return [#warn, nil] logger used for swallowed transport errors.
    attr_accessor :logger

    # @return [Array<String>] absolute path prefixes considered "in app".
    attr_reader :project_root

    # @return [Regexp, nil] keys matching this are redacted in captured bags.
    #   nil disables scrubbing.
    attr_accessor :sensitive_fields

    # @return [Array<String>] exception class names (and their subclasses) that
    #   are dropped before capture. Defaults to {DEFAULT_EXCLUDED_EXCEPTIONS}.
    #   Assign to replace, or use `+=` to append. Set to `[]` to disable.
    attr_accessor :excluded_exceptions

    def initialize
      @api_key     = ENV["REWINDREWIND_PROJECT_KEY"] || ENV["REWINDREWIND_API_KEY"]
      @endpoint    = (ENV["REWINDREWIND_ENDPOINT"] || DEFAULT_ENDPOINT).sub(%r{/+\z}, "")
      @environment = ENV["REWINDREWIND_ENVIRONMENT"] || ENV["RACK_ENV"] || ENV["RAILS_ENV"]
      @release     = ENV["REWINDREWIND_RELEASE"]
      @tags        = {}
      @timeout     = (ENV["REWINDREWIND_TIMEOUT"] || DEFAULT_TIMEOUT).to_f
      @enabled     = true
      @logger      = nil
      @sensitive_fields = DEFAULT_SENSITIVE_FIELDS
      @excluded_exceptions = DEFAULT_EXCLUDED_EXCEPTIONS.dup
      self.project_root = ENV["REWINDREWIND_PROJECT_ROOT"] || infer_project_root
    end

    # Sets the ingest endpoint, validating the scheme/host so the project key
    # (sent as a Bearer token) is never transmitted in cleartext to an arbitrary
    # host. https is always allowed; http is allowed only for localhost.
    #
    # @raise [ArgumentError] if the URL is unparseable or not permitted.
    def endpoint=(value)
      normalized = value.to_s.sub(%r{/+\z}, "")
      validate_endpoint!(normalized)
      @endpoint = normalized
    end

    # Accepts a single path or a list of paths. Stored as absolute strings.
    def project_root=(value)
      @project_root = Array(value).flatten.compact.map { |p| File.expand_path(p.to_s) }
    end

    # The gem is usable only when it has somewhere to send data and is enabled
    # and supplied with the protocol-required environment.
    def usable?
      enabled && present?(api_key) && present?(environment)
    end

    # Validates the environment string against the wire protocol constraints,
    # truncating overly long values rather than rejecting a capture outright.
    def normalized_environment
      env = environment.to_s.strip
      env.length > MAX_ENVIRONMENT_LENGTH ? env[0, MAX_ENVIRONMENT_LENGTH] : env
    end

    private

    def validate_endpoint!(value)
      uri = URI.parse(value)
      scheme = uri.scheme&.downcase
      host = uri.host&.downcase

      case scheme
      when "https"
        nil
      when "http"
        unless LOCALHOST_HOSTS.include?(host)
          raise ArgumentError,
                "RewindRewind endpoint must use https (got http://#{uri.host}); " \
                "plain http is only allowed for localhost"
        end
      else
        raise ArgumentError,
              "RewindRewind endpoint must be an http(s) URL (got #{value.inspect})"
      end
    rescue URI::InvalidURIError
      raise ArgumentError, "RewindRewind endpoint is not a valid URL: #{value.inspect}"
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end

    # Best-effort guess at the application root when the host doesn't set one.
    # Uses Bundler's gemfile dir if available, otherwise the process cwd.
    def infer_project_root
      if defined?(Bundler) && Bundler.respond_to?(:root)
        Bundler.root.to_s
      else
        Dir.pwd
      end
    rescue StandardError
      Dir.pwd
    end
  end
end
