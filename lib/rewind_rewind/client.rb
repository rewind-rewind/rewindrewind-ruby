# frozen_string_literal: true

require "json"
require "net/http"
require "openssl"
require "uri"

require_relative "backtrace"

module RewindRewind
  # Transport + payload assembly for the RewindRewind ingest API.
  #
  # A Client is framework-agnostic: it depends only on a {Configuration} and the
  # Ruby standard library. Capture methods never raise into the caller — any
  # transport or serialisation failure is swallowed and logged.
  class Client
    EXCEPTIONS_PATH = "/v1/exceptions"
    EVENTS_PATH     = "/v1/events"
    PLATFORM        = "ruby"
    MAX_FRAMES      = 50

    # Replacement value written in place of a redacted sensitive field.
    FILTERED = "[FILTERED]"

    # Payload bags that carry caller-supplied data and are therefore run through
    # the sensitive-field scrubber before being POSTed. Everything else in the
    # payload is SDK-controlled metadata.
    SCRUBBED_KEYS = %i[extra tags user request properties].freeze

    # @return [RewindRewind::Configuration]
    attr_reader :configuration

    def initialize(configuration)
      @configuration = configuration
    end

    # Capture a Ruby exception (or any object responding to #message/#backtrace).
    #
    # @param exception [Exception]
    # @param level [String] severity, defaults to "error"
    # @param fingerprint [String, Array, nil] optional dedupe override
    # @param tags [Hash] merged over the configured tags
    # @param extra [Hash] arbitrary structured context
    # @param user [Hash, nil] {id:, email:} (other keys allowed)
    # @param request [Hash, nil] request context (method/path/url/...)
    # @param environment [String, nil] per-call environment override
    # @param release [String, nil] per-call release override
    # @return [Boolean] true on 2xx, false otherwise (never raises)
    def capture_exception(exception, level: "error", fingerprint: nil, tags: {},
                          extra: {}, user: nil, request: nil, environment: nil,
                          release: nil)
      if excluded_exception?(exception)
        log_dropped(exception)
        return false
      end

      payload = {
        timestamp: now_ms,
        environment: resolve_environment(environment),
        release: release || configuration.release,
        platform: PLATFORM,
        level: (level || "error").to_s,
        message: message_for(exception),
        fingerprint: normalize_fingerprint(fingerprint),
        exception: {
          type: exception_type(exception),
          value: message_for(exception),
          stacktrace: Backtrace.parse(safe_backtrace(exception), configuration, limit: MAX_FRAMES)
        },
        request: presence(request),
        user: presence(user),
        tags: merged_tags(tags),
        extra: presence(extra)
      }

      post(EXCEPTIONS_PATH, payload)
    rescue StandardError => e
      log_failure(:capture_exception, e)
      false
    end

    # Capture a product/analytics event.
    #
    # @param type [String] event name (REQUIRED)
    # @return [Boolean] true on 2xx, false otherwise (never raises)
    def capture_event(type, properties: {}, distinct_id: nil, anonymous_id: nil,
                      source: nil, environment: nil, release: nil)
      raise ArgumentError, "event type is required" if blank?(type)

      payload = {
        type: type.to_s,
        environment: resolve_environment(environment),
        release: release || configuration.release,
        distinct_id: distinct_id,
        anonymous_id: anonymous_id,
        source: source,
        properties: merged_tags(properties)
      }

      post(EVENTS_PATH, payload)
    rescue StandardError => e
      log_failure(:capture_event, e)
      false
    end

    private

    # True when the exception (or any of its ancestors), or anything in its
    # `cause` chain (and their ancestors), has a fully-qualified class NAME that
    # appears in the configured {Configuration#excluded_exceptions} list. The
    # ancestry walk means a subclass of an excluded class is also excluded; the
    # cause walk is defensive against wrappers that re-raise a framework 4xx as
    # their own type. Matching is by name string, so the listed classes need not
    # be defined (loaded) in this process.
    def excluded_exception?(exception)
      excluded = configuration.excluded_exceptions
      return false if excluded.nil? || excluded.empty?

      list = excluded.map(&:to_s)
      seen = {}
      current = exception
      while current
        break if seen[current.object_id]

        seen[current.object_id] = true
        return true if ancestry_excluded?(current, list)

        current = current.respond_to?(:cause) ? current.cause : nil
      end
      false
    rescue StandardError
      false
    end

    def ancestry_excluded?(exception, list)
      klass = exception.is_a?(Exception) ? exception.class : exception.class
      klass.ancestors.any? do |ancestor|
        ancestor.respond_to?(:name) && list.include?(ancestor.name)
      end
    rescue StandardError
      false
    end

    def log_dropped(exception)
      logger = configuration.logger
      return unless logger.respond_to?(:debug)

      logger.debug("[RewindRewind] dropped excluded exception #{exception_type(exception)}")
    rescue StandardError
      nil
    end

    def post(path, body)
      uri = URI.parse("#{configuration.endpoint}#{path}")
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{configuration.api_key}"
      request["Content-Type"]  = "application/json"
      request["User-Agent"]    = "rewind_rewind-ruby/#{RewindRewind::VERSION}"
      request.body = JSON.generate(scrub_payload(compact(body)))

      response = http_for(uri).request(request)
      success = response.code.to_i.between?(200, 299)
      log_failure(path, "server returned #{response.code}") unless success
      success
    end

    def http_for(uri)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      if http.use_ssl?
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER
        http.min_version = OpenSSL::SSL::TLS1_2_VERSION
      end
      http.open_timeout = configuration.timeout
      http.read_timeout = configuration.timeout
      http.write_timeout = configuration.timeout if http.respond_to?(:write_timeout=)
      http
    end

    def resolve_environment(override)
      env = override.nil? || override.to_s.strip.empty? ? configuration.normalized_environment : override.to_s.strip
      raise ArgumentError, "environment is required" if env.empty?

      env[0, Configuration::MAX_ENVIRONMENT_LENGTH]
    end

    def merged_tags(extra)
      configuration.tags.merge(extra || {})
    end

    def exception_type(exception)
      exception.respond_to?(:class) ? exception.class.name : exception.class.to_s
    end

    def message_for(exception)
      if exception.respond_to?(:message)
        exception.message.to_s
      else
        exception.to_s
      end
    end

    def safe_backtrace(exception)
      exception.respond_to?(:backtrace) ? exception.backtrace : nil
    end

    def normalize_fingerprint(fingerprint)
      return nil if fingerprint.nil?

      Array(fingerprint).map(&:to_s).reject(&:empty?).then { |f| f.empty? ? nil : f }
    end

    def now_ms
      (Time.now.to_f * 1000).round
    end

    # Recursively drop nil values so optional fields are simply absent.
    def compact(value)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), acc|
          compacted = compact(v)
          acc[k] = compacted unless compacted.nil?
        end
      when Array
        value.map { |v| compact(v) }
      else
        value
      end
    end

    # Redact sensitive values in the caller-supplied bags (extra/tags/user/
    # request/properties) before they leave the process. SDK-controlled
    # metadata (message, level, stacktrace, ...) is left untouched.
    def scrub_payload(payload)
      pattern = configuration.sensitive_fields
      return payload if pattern.nil? || !payload.is_a?(Hash)

      payload.each_with_object({}) do |(key, value), acc|
        acc[key] = SCRUBBED_KEYS.include?(key) ? scrub(value, pattern) : value
      end
    end

    # Recursively walk hashes/arrays, replacing any hash value whose KEY matches
    # the denylist with FILTERED. Matching is by key name only, so intentional
    # attribution like user[:id]/user[:email] survives (they aren't on the list).
    def scrub(value, pattern)
      case value
      when Hash
        value.each_with_object({}) do |(k, v), acc|
          acc[k] = sensitive_key?(k, pattern) ? FILTERED : scrub(v, pattern)
        end
      when Array
        value.map { |v| scrub(v, pattern) }
      else
        value
      end
    end

    def sensitive_key?(key, pattern)
      pattern.match?(key.to_s)
    end

    def presence(value)
      return nil if value.nil?
      return nil if value.respond_to?(:empty?) && value.empty?

      value
    end

    def blank?(value)
      value.nil? || value.to_s.strip.empty?
    end

    def log_failure(context, error)
      logger = configuration.logger
      return unless logger.respond_to?(:warn)

      detail = error.is_a?(Exception) ? "#{error.class}: #{error.message}" : error.to_s
      logger.warn("[RewindRewind] #{context} failed: #{detail}")
    rescue StandardError
      nil
    end
  end
end
