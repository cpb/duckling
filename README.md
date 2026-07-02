# Duckling

Ruby FFI adapter to a Rust [Duckling](https://github.com/wafer-inc/duckling) NER engine — no HTTP service required.

## Installation

Install the gem and add to the application's Gemfile by executing:

```bash
bundle add duckling
```

If bundler is not being used to manage dependencies, install the gem by executing:

```bash
gem install duckling
```

## Usage

```ruby
require "duckling"

Duckling.parse("tomorrow", locale: "en")
# =>
# [#<data Duckling::Entity body="tomorrow", start=0, end=8, dim=:time, latent=false,
#    value=#<data Duckling::TimeValue::Single
#      value=#<data Duckling::TimePoint::Naive value="2026-07-03T00:00:00", grain=:day>,
#      values=[...], holiday=nil>>]
# (the date resolves relative to now; pass reference_time: for a fixed anchor)
```

`Duckling.parse` takes required text plus keyword options, and returns an
`Array` of `Duckling::Entity` objects (empty if nothing matched):

```ruby
Duckling.parse(text, locale: "en", dims: ["time"], reference_time: nil, with_latent: false)
```

Entities and their nested values are immutable [`Data`](https://docs.ruby-lang.org/en/master/Data.html)
objects, not `Hash`es — access fields with method calls (`entity.body`,
`entity.value.grain`, ...) rather than `entity[:body]`. They support
`case/in` pattern matching via `deconstruct`/`deconstruct_keys` like any
other `Data` object.

### Keyword arguments

- `locale:` (String, default `"en"`) — a `lang[-region]` tag, e.g. `"en"` or
  `"en-GB"`. An unrecognized language or region raises `ArgumentError`.
- `dims:` (Array of String, default `["time"]`) — which dimensions to
  extract. See "Supported dimensions" below — only `"time"` gets a dedicated
  `Data` value type today. An unrecognized dimension name raises
  `ArgumentError`.
- `reference_time:` (Integer Unix seconds, default `nil`) — anchors relative
  expressions like "tomorrow" or "next week". Defaults to the current UTC
  time; pass an explicit value for deterministic output.
- `with_latent:` (Boolean, default `false`) — include ambiguous/latent
  matches (e.g. a bare "morning") in the results.

There is no `Duckling::Error` class — invalid `locale:`/`dims:` values raise
plain `ArgumentError`.

### Return value

Each entity in the returned array is a `Duckling::Entity`:

- `body` (String) — the matched substring.
- `start` / `end` (Integer) — character offsets into the input text.
- `dim` (Symbol) — the dimension, e.g. `:time`.
- `latent` (Boolean) — `true` for ambiguous/latent matches, `false` otherwise.
- `value` — shape depends on `dim`; see "Supported dimensions" below. For
  `:time`, it's a `Duckling::TimeValue::Single` or `::Interval`:

  ```ruby
  # a single point in time, e.g. "tomorrow"
  #<data Duckling::TimeValue::Single
    value=#<data Duckling::TimePoint::Naive value="2026-07-03T00:00:00", grain=:day>,
    values=[...], holiday=nil>

  # an interval, e.g. "from 3pm to 5pm"
  #<data Duckling::TimeValue::Interval
    from=#<data Duckling::TimePoint::Naive value="2013-02-12T15:00:00", grain=:hour>,
    to=#<data Duckling::TimePoint::Naive value="2013-02-12T18:00:00", grain=:hour>,
    values=[...], holiday=nil>
  ```

  A `Duckling::TimePoint` is either `::Naive` (a wall-clock time with no
  timezone, e.g. "tomorrow", "5pm") or `::Instant` (an absolute fixed-offset
  moment, e.g. "in 2 hours", "now") — both expose `value` (String) and
  `grain` (Symbol). `grain` is one of `second`, `minute`, `hour`, `day`,
  `week`, `month`, `quarter`, `year`, or `no_grain`.

  **Gotcha:** an interval's `to` is the *exclusive* boundary, not the
  literal named time — `"from 3pm to 5pm"` resolves `to` to `18:00`, not
  `17:00`. This matches upstream [duckling](https://github.com/wafer-inc/duckling)
  behavior.

### Supported dimensions

Only `"time"` gets a dedicated `Data` value type today (`Duckling::TimeValue`/
`Duckling::TimePoint`, above). Other dimension names (`number`, `ordinal`,
`temperature`, `distance`, `volume`, `quantity`, `amount-of-money`, `email`,
`phone-number`, `url`, `credit-card-number`, `time-grain`, `duration`) are
accepted by `dims:` without error, and their entities' `value` is populated
with whatever the wrapped duckling crate resolved — a plain Ruby scalar
(`String`/`Float`/`Integer`) for simple dimensions like `email` or `number`,
or a raw symbol-keyed `Hash` for structured ones (e.g. `quantity`), rather
than a dedicated `Data` type. Dedicated value types for these are planned for
future releases.

### Advanced: raw output

`Duckling::Native.parse` (same arguments as `Duckling.parse`) returns the raw
symbol-keyed, externally-tagged `Hash` the native extension produces, before
`Duckling.parse` converts it into `Data` objects — e.g. `{value: {Time:
{Single: {value: {Naive: {value: "...", grain: "Day"}}, values: [...]}}}}`.
It's faster (skips the `Data`-object allocation and `case/in` conversion
layer) but its shape isn't part of this gem's stable public API in the way
`Duckling.parse`'s `Data` objects are — prefer `Duckling.parse` unless you've
measured the difference mattering for your workload.

### Known limitation: bare comma-separated lists

A run of date/time expressions joined by bare commas, with nothing else
between them, collapses into a single entity — every date after the first
in that run is silently dropped:

```ruby
Duckling.parse("birthdays are march 3, march 9, april 12 and may 5", locale: "en")
  .select { |r| r.dim == :time }
  .map { |r| r.value.value.value }
# => ["2013-03-03T00:00:00", "2013-05-05T00:00:00"]
# (march 9 and april 12 are silently dropped)
```

This is an upstream grammar/ranking behavior in the wrapped
[duckling](https://github.com/wafer-inc/duckling) engine, not something this
gem can work around. Joining
dates with "and", periods, or a name/label immediately before each date
avoids the collapse:

```ruby
Duckling.parse("march 3 and march 9 and april 12 and may 5", locale: "en")
  .select { |r| r.dim == :time }
  .map { |r| r.value.value.value }
# => ["2013-03-03T00:00:00", "2013-03-09T00:00:00", "2013-04-12T00:00:00", "2013-05-05T00:00:00"]
```

See `test/duckling_comma_list_test.rb` for the full characterization,
including cases where the surviving value isn't even reliably the leftmost
date in the collapsed run.

## Development

After checking out the repo, run `bin/setup` to install dependencies. Building
the native Rust extension requires a Rust toolchain; on macOS with Homebrew
installed, `bin/setup` installs it automatically via `brew bundle` and the
project's `Brewfile` (no-op if Homebrew isn't present). Then run
`rake compile` to build the extension before running `rake test`, or just run
`rake` (or `bundle exec rake`) with no arguments to lint, compile, and test in
order. You can also run `bin/console` for an interactive prompt that will
allow you to experiment.

`bin/setup` also seeds a `.env.local` file (from `.env.local.example`) with
`RB_SYS_CARGO_PROFILE=dev`, so local `rake compile` runs build the extension
in Cargo's dev profile by default — slower at runtime, but much faster to
compile while iterating. `.env.local` is gitignored and untouched by CI, so
CI and `rake release` still build the optimized release profile. Delete or
edit `.env.local` to opt back into a release-profile local build, or run
`bundle exec rake dev compile test` for a one-off dev-profile build without
`.env.local` in place.

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version: bump `Duckling::VERSION` in `version.rb`, merge that change to `main`, then run `bundle exec rake release` (or push a matching `vX.Y.Z` tag directly) to create and push the git tag. Pushing the tag triggers a GitHub Actions pipeline that re-runs CI as a gate, verifies the tag matches `Duckling::VERSION`, builds and publishes the gem to [rubygems.org](https://rubygems.org), cuts a GitHub release, and opens a PR appending an entry to `CHANGELOG.md`.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/cpb/duckling. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/cpb/duckling/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Duckling project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/cpb/duckling/blob/master/CODE_OF_CONDUCT.md).
