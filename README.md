# RewindRewind Ruby SDK

The official Ruby SDK for [RewindRewind](https://rewindrewind.com). It captures
exceptions and product events from plain Ruby programs and Rack applications
without runtime gem dependencies.

Rails applications should use the separate
[`rewind_rewind-rails`](https://github.com/rewind-rewind/rewindrewind-rails) gem,
which depends on this SDK and adds automatic framework integration.

## Requirements

Ruby 3.0 or newer.

## Installation

Install from the RewindRewind gem index:

```ruby
# Gemfile
source "https://rewindrewind.com/gems" do
  gem "rewind_rewind"
end
```

Then run `bundle install`. Without Bundler, run:

```sh
gem install rewind_rewind --source https://rewindrewind.com/gems
```

The SDK uses only Ruby's standard library, including `net/http`, `json`, and
`uri`.

## Quick start

```ruby
require "rewind_rewind"

RewindRewind.configure do |config|
  config.api_key     = ENV.fetch("REWINDREWIND_PROJECT_KEY") # rrpub_xxx
  config.environment = "production"
  config.release     = ENV["GIT_SHA"]
  config.tags        = { service: "ingest-worker" }
end

begin
  risky_operation!
rescue => error
  RewindRewind.capture_exception(error, tags: { queue: "critical" })
  raise
end
```

Project keys start with `rrpub_` and are public ingestion credentials. Do not
put an admin key, which starts with `rr_`, in application code.

## Configuration

| Setting | Default | Notes |
| --- | --- | --- |
| `api_key` | `REWINDREWIND_PROJECT_KEY`, then `REWINDREWIND_API_KEY` | Required project key |
| `endpoint` | `REWINDREWIND_ENDPOINT`, then `https://rewindrewind.com` | Trailing slash removed; explicit assignments require HTTPS except for localhost |
| `environment` | `REWINDREWIND_ENVIRONMENT`, `RACK_ENV`, then `RAILS_ENV` | Required; trimmed and limited to 64 characters |
| `release` | `REWINDREWIND_RELEASE` | Optional release or Git SHA |
| `tags` | `{}` | Merged into exception tags and event properties |
| `timeout` | `REWINDREWIND_TIMEOUT`, then `2.0` seconds | Open, read, and write timeout |
| `enabled` | `true` | Set to `false` to disable all capture |
| `logger` | `nil` | Receives warnings for swallowed failures |
| `project_root` | Bundler root, then current directory | Used for `in_app` stack frames |
| `sensitive_fields` | Built-in regular expression | Matching keys are redacted; set to `nil` to disable |
| `excluded_exceptions` | `[]` | Class names to drop; matching includes subclasses and wrapped causes |

If the key or environment is missing, or `enabled` is false, no client is built.
Capture calls then return `false` without sending data.

## Capturing exceptions

```ruby
RewindRewind.capture_exception(
  error,
  level:       "error",
  fingerprint: ["billing", "v2"],
  tags:        { tenant: "acme" },
  extra:       { invoice_id: 42 },
  identity:    { id: "u_1", email: "a@example.com" },
  request:     { method: "POST", path: "/charge" },
  environment: "production",
  release:     "web@1.4.3"
)
```

Capture calls never raise into application code. They return `true` for a
successful HTTP response and `false` when disabled, excluded, or unsuccessful.
Transport and serialization failures are logged when `logger` is configured.

## Capturing events

```ruby
RewindRewind.capture_event(
  "checkout.completed",
  properties:   { amount_cents: 4200, currency: "usd" },
  identity_id:  "user_1",
  anonymous_id: "anon_abc",
  source:       "backend"
)
```

## Rack middleware

```ruby
# config.ru
require "rewind_rewind"

RewindRewind.configure do |config|
  config.api_key     = ENV.fetch("REWINDREWIND_PROJECT_KEY")
  config.environment = ENV.fetch("RACK_ENV", "production")
end

use RewindRewind::Rack
run MyApp
```

The middleware reports unhandled exceptions with the request method, path, URL,
IP address, and user agent. It omits query strings, then re-raises the exception
so normal application error handling remains intact.

## Data safety

Before sending a payload, the SDK recursively redacts values under sensitive
keys in `extra`, `tags`, `identity`, `request`, and event `properties`. The default
pattern covers passwords, secrets, tokens, authorization data, API and access
keys, cookies, sessions, credentials, payment card data, SSNs, and private keys.
Redacted values become `"[FILTERED]"`.

The SDK captures every exception class by default. If particular framework 4xx
exceptions are known to be non-actionable for your application, opt into the
suggested list:

```ruby
config.excluded_exceptions =
  RewindRewind::Configuration::SUGGESTED_EXCLUDED_EXCEPTIONS
```

You can also provide your own array or append entries with `+=`. Matching
includes subclasses and wrapped causes.

## Stack frame classification

RewindRewind derives an issue's culprit from the first stack frame marked
`in_app: true`, falling back to the last frame. The SDK marks a frame as
application code only when its path is under `project_root` and outside gem,
standard-library, vendored bundle, and version-manager paths. Set
`project_root` to one or more absolute paths to override detection.

## Development

```sh
bin/test
```

## License

MIT
