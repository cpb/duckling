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
# [{ body: "tomorrow", start: 0, end: 8, dim: :time,
#    value: { type: :value, value: "2026-07-02T00:00:00", grain: :day, values: [...] } }]
# (the date resolves relative to now; pass reference_time: for a fixed anchor)
```

`Duckling.parse` takes required text plus keyword options, and returns an
`Array` of entity `Hash`es (empty if nothing matched):

```ruby
Duckling.parse(text, locale: "en", dims: ["time"], reference_time: nil, with_latent: false)
```

### Keyword arguments

- `locale:` (String, default `"en"`) — a `lang[-region]` tag, e.g. `"en"` or
  `"en-GB"`. An unrecognized language or region raises `ArgumentError`.
- `dims:` (Array of String, default `["time"]`) — which dimensions to
  extract. See "Supported dimensions" below — only `"time"` currently
  produces a populated `:value`. An unrecognized dimension name raises
  `ArgumentError`.
- `reference_time:` (`Time`, default `nil`) — anchors relative expressions
  like "tomorrow" or "next week". Its `utc_offset` is preserved into
  offset-aware results (e.g. `"in one hour"`), not flattened to UTC. Defaults
  to the current UTC time; pass an explicit `Time` for deterministic output.
  A non-`Time` value (e.g. a raw Integer) raises `TypeError`.
- `with_latent:` (Boolean, default `false`) — include ambiguous/latent
  matches (e.g. a bare "morning") in the results.

There is no `Duckling::Error` class — invalid `locale:`/`dims:` values raise
plain `ArgumentError`.

### Return value

Each entity in the returned array is a `Hash` with:

- `:body` (String) — the matched substring.
- `:start` / `:end` (Integer) — character offsets into the input text.
- `:dim` (Symbol) — the dimension, e.g. `:time`.
- `:latent` (Boolean) — present only when the match is latent.
- `:value` (Hash) — present only for the `:time` dimension today. Shape
  depends on whether it's a single point in time or an interval:

  ```ruby
  # a single point in time, e.g. "tomorrow"
  { type: :value, value: "2026-07-02T00:00:00", grain: :day, values: [...] }

  # an interval, e.g. "from 3pm to 5pm"
  { type: :interval,
    from: { type: :value, value: "2013-02-12T15:00:00", grain: :hour },
    to:   { type: :value, value: "2013-02-12T18:00:00", grain: :hour } }
  ```

  `grain` is one of `second`, `minute`, `hour`, `day`, `week`, `month`,
  `quarter`, `year`.

  **Gotcha:** an interval's `:to` is the *exclusive* boundary, not the
  literal named time — `"from 3pm to 5pm"` resolves `:to` to `18:00`, not
  `17:00`. This matches upstream [duckling](https://github.com/wafer-inc/duckling)
  behavior.

### Supported dimensions

In 0.2.0, only `"time"` is fully supported — it's the only dimension whose
entities come back with a populated `:value`. Other dimension names
(`number`, `ordinal`, `temperature`, `distance`, `volume`, `quantity`,
`amount-of-money`, `email`, `phone-number`, `url`, `credit-card-number`,
`time-grain`, `duration`) are accepted by `dims:` without error, but their
entities currently have no `:value` key. Broader dimension support is
planned for future releases.

### Known limitation: bare comma-separated lists

A run of date/time expressions joined by bare commas, with nothing else
between them, collapses into a single entity — every date after the first
in that run is silently dropped:

```ruby
Duckling.parse("birthdays are march 3, march 9, april 12 and may 5", locale: "en")
  .select { |r| r[:dim] == :time }
  .map { |r| r[:value][:value] }
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
  .select { |r| r[:dim] == :time }
  .map { |r| r[:value][:value] }
# => ["2013-03-03T00:00:00", "2013-03-09T00:00:00", "2013-04-12T00:00:00", "2013-05-05T00:00:00"]
```

See `test/duckling_comma_list_test.rb` for the full characterization,
including cases where the surviving value isn't even reliably the leftmost
date in the collapsed run.

## Performance

Benchmarked with [benchmark-ips](https://github.com/evanphx/benchmark-ips)
against `Duckling.parse`, including Magnus/Ruby conversion overhead (not
just the underlying Rust engine), plus GC pressure and threaded-worker-pool
throughput. See [`docs/benchmarks/`](docs/benchmarks/) for the latest
numbers, broken out by environment (GitHub Actions CI, Claude Code Web,
local dev) — results vary enough by machine that comparing across
environments is more meaningful than a single blended trend.

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

To install this gem onto your local machine, run `bundle exec rake install`. To release a new version: bump `Duckling::VERSION` in `version.rb`, merge that change to `main`, then run `bundle exec rake release` (or push a matching `vX.Y.Z` tag directly) to create and push the git tag. Pushing the tag triggers a GitHub Actions pipeline that re-runs CI as a gate, cross-compiles `x86_64-linux`/`x86_64-darwin` binary gems, verifies the tag matches `Duckling::VERSION`, builds and publishes the gems (source + both binary platforms) to [rubygems.org](https://rubygems.org), cuts a GitHub release, and opens a PR appending an entry to `CHANGELOG.md`.

`bin/benchmark` (or `bundle exec rake benchmark`) runs the `benchmark-ips`
suite locally and prints results to the console — no files written.
`bin/benchmark record` (or `rake benchmark:record`) additionally writes
`docs/benchmarks/<environment>/<version>.json` and regenerates
`docs/benchmarks/README.md`. `bin/benchmark record-pr` (or `rake
benchmark:record_pr`) does the same against a fresh branch off `origin/main`
and opens (and auto-merges) a PR via `gh` — this is what the release
pipeline runs automatically, and what you'd also run from a Claude Code Web
session or a local dev machine to contribute that environment's numbers
ahead of a release. `gh` needs to be installed (`bin/setup` does this via
the `Brewfile` on macOS) and authenticated (`gh auth login`) for the
`record-pr` variant.

## Contributing

Bug reports and pull requests are welcome on GitHub at https://github.com/cpb/duckling. This project is intended to be a safe, welcoming space for collaboration, and contributors are expected to adhere to the [code of conduct](https://github.com/cpb/duckling/blob/master/CODE_OF_CONDUCT.md).

## License

The gem is available as open source under the terms of the [MIT License](https://opensource.org/licenses/MIT).

## Code of Conduct

Everyone interacting in the Duckling project's codebases, issue trackers, chat rooms and mailing lists is expected to follow the [code of conduct](https://github.com/cpb/duckling/blob/master/CODE_OF_CONDUCT.md).
