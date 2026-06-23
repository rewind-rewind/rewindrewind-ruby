# frozen_string_literal: true

require_relative "lib/rewind_rewind/version"

Gem::Specification.new do |spec|
  spec.name        = "rewind_rewind"
  spec.version     = RewindRewind::VERSION
  spec.summary     = "Ruby SDK for RewindRewind exception and event tracking"
  spec.description = "Framework-agnostic Ruby client for the RewindRewind " \
                     "observability service. Depends only on the standard " \
                     "library. Rails apps should use the rewind_rewind-rails gem."
  spec.authors  = ["RewindRewind"]
  spec.email    = ["sdk@rewindrewind.com"]
  spec.homepage = "https://rewindrewind.com"
  spec.license  = "MIT"

  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*.rb"] + ["README.md"]
  spec.require_paths = ["lib"]

  spec.metadata["homepage_uri"]    = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/rewind-rewind/rewindrewind-ruby"
  spec.metadata["rubygems_mfa_required"] = "true"

  # No runtime dependencies — net/http, json and uri ship with Ruby.
  spec.add_development_dependency "minitest", "~> 5.0"
  spec.add_development_dependency "rake", "~> 13.0"
end
