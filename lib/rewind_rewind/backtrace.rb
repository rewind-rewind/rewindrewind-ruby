# frozen_string_literal: true

module RewindRewind
  # Parses Ruby backtrace lines into structured stack frames and, crucially,
  # decides which frames are "in app".
  #
  # The RewindRewind server derives an issue's culprit from the *first*
  # `in_app: true` frame (falling back to the last frame). Getting in_app
  # detection right is therefore the single most important fidelity concern
  # for the SDK: application frames must be flagged true and gem/stdlib/vendor
  # frames must be flagged false, so that culprits point at the host app's
  # code rather than at net/http or some dependency.
  module Backtrace
    # Standard Ruby backtrace line, e.g.
    #   /app/lib/foo.rb:42:in `bar'
    #   /app/lib/foo.rb:42:in 'Foo#bar'   (Ruby 3.4+ quoting)
    LINE_PATTERN = /\A(?<file>.+?):(?<line>\d+)(?::in [`']?(?<function>.*?)['`]?)?\z/

    # Path fragments that mark a frame as belonging to a dependency or the
    # runtime rather than the application under observation.
    NON_APP_MARKERS = [
      "/gems/",
      "/ruby/gems/",
      "/vendor/bundle/",
      "/vendor/cache/",
      "/.bundle/",
      "/.rbenv/",
      "/.rvm/",
      "/.asdf/",
      "/rubygems/",
      "<internal:" # frozen / C-defined frames
    ].freeze

    module_function

    # @param backtrace [Array<String>, nil] raw `exception.backtrace`
    # @param config [RewindRewind::Configuration]
    # @param limit [Integer] maximum number of frames to serialise
    # @return [Array<Hash>] ordered frames, innermost (raise site) first
    def parse(backtrace, config, limit: 50)
      roots = config.project_root
      Array(backtrace).first(limit).map { |line| frame_for(line, roots) }.compact
    end

    # @return [Hash, nil] a single serialised frame, or nil if unparseable
    def frame_for(line, roots)
      match = LINE_PATTERN.match(line.to_s)
      return fallback_frame(line, roots) unless match

      filename = match[:file]
      {
        filename: filename,
        function: match[:function],
        line: match[:line].to_i,
        in_app: in_app?(filename, roots),
        module: module_name(match[:function])
      }.compact
    end

    # A frame is in_app when it lives under one of the configured project roots
    # AND is not inside a gems / stdlib / vendored-bundle path.
    def in_app?(filename, roots)
      path = filename.to_s
      return false if path.empty?
      return false if dependency_path?(path)
      return false if roots.nil? || roots.empty?

      absolute = absolute_path(path)
      roots.any? { |root| under?(absolute, root) }
    end

    def dependency_path?(path)
      NON_APP_MARKERS.any? { |marker| path.include?(marker) }
    end

    # Frames whose path is relative (e.g. "smoke.rb" or "(eval)") still belong
    # to the app if they aren't dependency paths; expand them against cwd so the
    # under?-check against the project root works consistently.
    def absolute_path(path)
      return path if path.start_with?("/")

      File.expand_path(path)
    rescue StandardError
      path
    end

    def under?(absolute, root)
      return false if root.nil? || root.empty?

      absolute == root ||
        absolute.start_with?(root.end_with?("/") ? root : "#{root}/")
    end

    # Best-effort: derive a Ruby module/class from a function label like
    # "Foo::Bar#baz" or "Foo::Bar.baz" → "Foo::Bar". Returns nil for bare
    # functions such as "<main>" or "block in run" that carry no receiver.
    def module_name(function)
      return nil if function.nil? || function.empty?
      return nil unless function =~ /[#.]/

      head = function.split(/[#.]/, 2).first.to_s
      head.empty? ? nil : head
    end

    # When a line doesn't match the canonical pattern we still emit a frame so
    # the stacktrace stays complete, marking it non-app to be safe.
    def fallback_frame(line, roots)
      text = line.to_s
      return nil if text.empty?

      { filename: text, function: nil, line: 0, in_app: in_app?(text, roots) }
    end
  end
end
