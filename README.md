# RewindRewind Ruby SDK

The official Ruby client for [RewindRewind](https://rewindrewind.com) — exception
tracking and product events. It has a **framework-agnostic core** that works in
any plain Ruby program (no Rails required, zero runtime gem dependencies) and a
**separate, optional Rails integration** that loads automatically only when Rails
is present.

## Installation

```ruby
# Gemfile
gem "rewind_rewind"
```

```ruby
gem install rewind_rewind
```

The SDK uses only the Ruby standard library (`net/http`, `json`, `uri`).

## Quick start (plain Ruby)

```ruby
require "rewind_rewind"

RewindRewind.configure do |config|
  config.api_key     = ENV["REWINDREWIND_PROJECT_KEY"] # rrpub_...
  config.environment = "production"                    # REQUIRED, <= 64 chars
  config.release     = ENV["GIT_SHA"]                  # optional
  config.tags        = { service: "ingest-worker" }    # merged into every payload
end

begin
  risky_operation!
rescue => e
  RewindRewind.capture_exception(e, tags: { queue: "critical" })
  raise
end
```

Everything you can set:

| Setting        | Default                                   | Notes |
|----------------|-------------------------------------------|-------|
| `api_key`      | `ENV["REWINDREWIND_PROJECT_KEY"]`         | `Authorization: Bearer <key>` |
| `endpoint`     | `ENV["REWINDREWIND_ENDPOINT"]` or `https://rewindrewind.com` | trailing slash stripped |
| `environment`  | `ENV["REWINDREWIND_ENVIRONMENT"]` / `RACK_ENV` / `RAILS_ENV` | **required**, truncated to 64 chars |
| `release`      | `ENV["REWINDREWIND_RELEASE"]`             | |
| `tags`         | `{}`                                      | merged into every capture |
| `timeout`      | `2.0` seconds                             | open/read/write timeout |
| `enabled`      | `true`                                    | master kill switch |
| `logger`       | `nil`                                     | gets `warn` on swallowed transport errors |
| `project_root` | Bundler root / cwd                        | drives `in_app` frame detection |

If `api_key` or `environment` is missing, or `enabled` is false, the client is
**not** built and all capture calls become safe no-ops returning `false`.

## Capturing exceptions

```ruby
RewindRewind.capture_exception(
  error,
  level:       "error",            # or "warning", "info"
  fingerprint: ["billing", "v2"],  # optional dedupe override
  tags:        { tenant: "acme" }, # merged over configured tags
  extra:       { invoice_id: 42 }, # arbitrary structured context
  user:        { id: "u_1", email: "a@b.com" },
  request:     { method: "POST", path: "/charge" }
)
```

Captures **never raise** into your code. Transport failures are swallowed (and
logged via `config.logger` if set), and the call returns `true`/`false`.

## Capturing events

```ruby
RewindRewind.capture_event(
  "checkout.completed",
  properties:   { amount_cents: 4200, currency: "usd" },
  distinct_id:  "user_1",
  anonymous_id: "anon_abc",
  source:       "backend"
)
```

## Rack apps (Sinatra, Roda, bare Rack, …)

The middleware is pure Rack — no Rails involved:

```ruby
# config.ru
require "rewind_rewind"

RewindRewind.configure do |c|
  c.api_key     = ENV["REWINDREWIND_PROJECT_KEY"]
  c.environment = ENV["RACK_ENV"] || "production"
end

use RewindRewind::Rack
run MyApp
```

It reports unhandled exceptions (with request method/path/url/IP/user-agent
context) and then re-raises so your own error handling is untouched.

## Rails

Just add the gem. The bundled Railtie loads **only when Rails is defined** and:

- defaults `environment` to `Rails.env` and `project_root` to `Rails.root`,
- routes `config.logger` to `Rails.logger`,
- inserts `RewindRewind::Rack` into the middleware stack,
- subscribes to the Rails error reporter (`Rails.error`) so handled errors flow
  through too.

Set your key (and any tags/release) in an initializer:

```ruby
# config/initializers/rewind_rewind.rb
RewindRewind.configure do |c|
  c.api_key = Rails.application.credentials.rewind_rewind_key
  c.release = ENV["GIT_SHA"]
  c.tags    = { app: "store" }
end
```

## How `in_app` frame detection works

RewindRewind derives an issue's **culprit** from the first `in_app: true` stack
frame (falling back to the last frame). The SDK therefore flags a frame as
in-app only when its file path lives **under the configured `project_root`** and
is **not** inside a gems / Ruby stdlib / `vendor/bundle` / version-manager path.
This keeps culprits pointing at your application code instead of `net/http` or a
dependency. Override detection by setting `config.project_root` to one or more
absolute paths.

## License

MIT
