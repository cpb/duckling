# stage130 — build slice manifest

Assembles the record every issue-ops template renders from. One entry per
slice: its key and slug, its wave, its kind (`time_form`, `modifiers`,
`dimension`), the Rust enum excerpt for its variant, how many times the
resolver in `mod.rs` mentions it, and its owned rules.

42 slices: 37 `TimeForm` variants + 1 modifier slice + 4 dependency
dimensions. By wave: A 30, B 9, C 3.

The resolver reference count is a rough size signal for the audit stage —
`Composed` is mentioned 20 times in `mod.rs`, `NthGrain` twice. It says how
much resolver logic a slice implies beyond its rule count.

Output: `out/slices.json`.
