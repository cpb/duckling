# Plans — Issue #1: Ship duckling gem (time extraction via Magnus + wafer-inc-duckling)

**0.2.0 has shipped.** The original three-plan implementation sequence (native
extension → Ruby API → test suite/CI) fully executed — see
[`stale/`](./stale/README.md) for that historical record.

This document is now the live plan: **what's left, tracked as GitHub issues**, not
prose duplicated here. Nothing below needs to happen for the gem to work today —
these are 0.2.x-and-beyond follow-ups raised during PR #3 review and while re-verifying
the stale plans against what actually shipped.

## Environment & tooling alignment

Keep local dev, Claude Code Web, and CI targeting the same Ruby/Rust versions so nothing
needs manual installation in any of them.

| Issue | What |
|-------|------|
| [#26](https://github.com/cpb/duckling/issues/26) | `bin/setup` on macOS: maintain a `Brewfile` + `brew bundle` step for non-gem deps (Rust) |
| [#27](https://github.com/cpb/duckling/issues/27) | Fill in the no-op `bin/claude-code-web-setup` skeleton with just-in-time dependency install |
| [#28](https://github.com/cpb/duckling/issues/28) | Pin CI's Rust toolchain to what's pre-installed in Claude Code Web, instead of floating on `stable` |
| [#29](https://github.com/cpb/duckling/issues/29) | Expand the CI matrix to Ruby 3.4 / latest Ruby / latest Rust (forward-compat signal) |
| [#43](https://github.com/cpb/duckling/issues/43) | Publish precompiled binary gems for `x86_64-darwin-24` and `x86_64-linux` |

## Developer workflow (Rakefile)

| Issue | What |
|-------|------|
| [#30](https://github.com/cpb/duckling/issues/30) | Add a `:dev` Rake task (`RB_SYS_CARGO_PROFILE=dev`) for a faster edit-compile-test loop |
| [#31](https://github.com/cpb/duckling/issues/31) | Explore making `test` explicitly depend on `:compile`, instead of relying on `default` task array ordering |

## API design exploration (post-0.2.0 direction)

The 0.2.0 API (manual Magnus hash mapping, matching pyduckling's Hash-based shape) is
not necessarily the final shape — see "Option D" in
[serialization-options.md](../research/type-mapping-strategy/serialization-options.md).

| Issue | What |
|-------|------|
| [#32](https://github.com/cpb/duckling/issues/32) | Explore serde_magnus (symbol keys) + Ruby pattern-matching `Data` factories as a Hash-free API |
| [#33](https://github.com/cpb/duckling/issues/33) | v0.3.0: handle Naive time values the Rails ActiveSupport way (resolve against reference zone) |
| [#45](https://github.com/cpb/duckling/issues/45) | `reference_time:` — accept a Ruby `Time` object to preserve UTC offset |
| [#46](https://github.com/cpb/duckling/issues/46) | Implement the remaining 13 `DimensionValue` variants beyond `Time` |
| [#47](https://github.com/cpb/duckling/issues/47) | Explore upstreaming serde container attributes to wafer-inc/duckling |

## Test coverage

| Issue | What |
|-------|------|
| [#34](https://github.com/cpb/duckling/issues/34) | Implement the extended test corpus designed in [ruby-test-design.md](../research/test-coverage/ruby-test-design.md) (`test-first`) |
| [#35](https://github.com/cpb/duckling/issues/35) | Audit wafer-inc-duckling's test coverage against pyduckling and upstream Haskell duckling |

## Performance & concurrency

| Issue | What |
|-------|------|
| [#36](https://github.com/cpb/duckling/issues/36) | Set up a `benchmark-ips` suite with automated README/CHANGELOG reporting |
| [#38](https://github.com/cpb/duckling/issues/38) | Test-drive the Falcon Fiber-blocking claim in [ffi-risks.md](../research/ffi-risks.md) (`test-first`) |

## Settled Decisions (0.2.0, verified shipped)

- **[duckling](https://github.com/wafer-inc/duckling) on crates.io** — Published as `duckling = "0.4"`.
- **Symbol keys and Symbol values throughout** — `:body`, `:dim`, `:value`, `:type`, `:grain`, etc. Settled by the hill tests in PR #2, confirmed shipped in `test/duckling_test.rb` on `main`.
- **NaiveDateTime → bare ISO8601 (no offset)** — Option N1. Shipped as-is; Option N2 (ActiveSupport-style zone resolution) is tracked for 0.3.0 as [#33](https://github.com/cpb/duckling/issues/33).
- **Manual Magnus mapping, not serde_magnus** — shipped as Option B; `magnus = "0.8"` (not `"0.9"`, which was never published to crates.io).
- **Source gem, not pre-compiled binaries** — shipped this way for 0.2.0; [#43](https://github.com/cpb/duckling/issues/43) tracks adding pre-compiled binary gems.
