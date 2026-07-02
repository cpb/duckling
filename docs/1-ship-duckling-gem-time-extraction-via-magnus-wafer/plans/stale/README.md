# Stale Plans — Fully Executed (0.2.0 Shipped)

These four documents were the sequenced implementation plan for PR #2 (native extension +
`Duckling.parse` + hill tests). **All of it shipped** — PR #2 merged, `v0.2.0` is tagged
and published on RubyGems, and the actual code on `main` matches what these plans
predicted (verified directly against
[`main@03a69e1`](https://github.com/cpb/duckling/tree/03a69e157a1543862c734ca8ac278a84600af315)
and later).

Kept here for historical/provenance value — they're the record of *why* 0.2.0 looks the
way it does — but they are not a live plan. **For what remains to be done, see
[`../README.md`](../README.md)**, which tracks the actual open work as GitHub issues.

| File | What it planned | Status |
|------|------------------|--------|
| [00-pr2-roadmap.md](./00-pr2-roadmap.md) | Step-by-step path from research to PR #2 green | Shipped — PR #2 merged, `v0.2.0` released |
| [01-native-extension-setup.md](./01-native-extension-setup.md) | Wire the `ext/duckling/` cdylib crate, `extconf.rb`, `Rakefile`, CI | Shipped — matches `ext/duckling/` and `Rakefile` on `main` |
| [02-ruby-api-design.md](./02-ruby-api-design.md) | `Duckling.parse` API design, manual Magnus mapping, symbol keys | Shipped — matches `ext/duckling/src/lib.rs` on `main` |
| [03-test-suite-and-ci.md](./03-test-suite-and-ci.md) | Hill test design, CI Rust toolchain step | Shipped — `test/duckling_test.rb` and `.github/workflows/main.yml` on `main` |

Every "Open Question" or "Post-PR-#2 follow-on work" item in these four documents that is
still genuinely open has been re-filed as a GitHub issue (see `../README.md`) rather than
left as prose here — so nothing was silently lost in this archive.
