# frozen_string_literal: true

require_relative "rewind_rewind/version"
require_relative "rewind_rewind/configuration"
require_relative "rewind_rewind/client"
require_relative "rewind_rewind/rack"

# RewindRewind Ruby SDK.
#
# The module-level API is a thin, thread-safe facade over a single configured
# {Client}. It is deliberately framework-agnostic: it requires only the Ruby
# standard library and knows nothing about Rails. Rails apps should instead use
# the `rewind_rewind-rails` gem, which depends on this one and auto-wires the
# Railtie. Plain Ruby / Sinatra / Roda apps use this gem directly (the pure
# {RewindRewind::Rack} middleware ships here).
#
# @example Plain Ruby
#   require "rewind_rewind"
#
#   RewindRewind.configure do |config|
#     config.api_key     = ENV["REWINDREWIND_PROJECT_KEY"]
#     config.environment = "production"
#     config.release     = ENV["GIT_SHA"]
#   end
#
#   begin
#     do_work!
#   rescue => e
#     RewindRewind.capture_exception(e, tags: { worker: "ingest" })
#     raise
#   end
module RewindRewind
  class << self
    # Configure (or reconfigure) the global client.
    #
    # @yieldparam config [RewindRewind::Configuration]
    # @return [RewindRewind::Configuration]
    def configure
      mutex.synchronize do
        @configuration = Configuration.new
        yield @configuration if block_given?
        @client = @configuration.usable? ? Client.new(@configuration) : nil
        @configuration
      end
    end

    # @return [RewindRewind::Configuration] the current (or default) config.
    def configuration
      @configuration ||= Configuration.new
    end

    # @return [RewindRewind::Client, nil] the active client, if usable.
    def client
      @client
    end

    # @return [Boolean] whether a usable client is configured.
    def configured?
      !@client.nil?
    end

    # Report an exception. No-ops (returning false) when unconfigured, and
    # never raises into the caller.
    #
    # @see RewindRewind::Client#capture_exception
    # @return [Boolean]
    def capture_exception(exception, **options)
      return false unless configured?

      @client.capture_exception(exception, **options)
    rescue StandardError => e
      log_internal_failure(:capture_exception, e)
      false
    end

    # Report a product/analytics event.
    #
    # @see RewindRewind::Client#capture_event
    # @return [Boolean]
    def capture_event(type, **options)
      return false unless configured?

      @client.capture_event(type, **options)
    rescue StandardError => e
      log_internal_failure(:capture_event, e)
      false
    end

    # Mark an exception object as already reported, so that a second capture
    # path (e.g. the Rack middleware vs. the Rails error subscriber) can skip
    # it. Tags the exception itself with an instance variable. Defensive: some
    # exception objects are frozen or otherwise reject ivar mutation, so any
    # failure is swallowed — at worst we lose dedup and fall back to the old
    # (latent) double-capture behaviour.
    #
    # @param error [Object] the exception object
    # @return [void]
    def mark_reported!(error)
      return unless error.is_a?(Object)

      error.instance_variable_set(:@__rewind_rewind_reported, true)
      nil
    rescue StandardError, FrozenError
      nil
    end

    # @param error [Object] the exception object
    # @return [Boolean] whether {#mark_reported!} has tagged this exact object.
    def already_reported?(error)
      return false unless error.is_a?(Object)

      !!error.instance_variable_get(:@__rewind_rewind_reported)
    rescue StandardError
      false
    end

    # Reset all state. Primarily a test helper.
    # @return [void]
    def reset!
      mutex.synchronize do
        @configuration = nil
        @client = nil
      end
    end

    private

    def mutex
      @mutex ||= Mutex.new
    end

    def log_internal_failure(context, error)
      logger = configuration.logger
      return unless logger.respond_to?(:warn)

      logger.warn("[RewindRewind] #{context} failed: #{error.class}: #{error.message}")
    rescue StandardError
      nil
    end
  end
end
