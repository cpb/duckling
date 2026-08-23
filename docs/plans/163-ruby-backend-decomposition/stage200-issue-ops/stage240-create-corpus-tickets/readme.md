# stage240 — create corpus tickets

Four issues that grow the corpus before anyone ports against it.

| Template | Issue | Source |
|---|---|---|
| `glob_split.md.erb` | split the local fixture into a globbed directory | hand-written |
| `unexercised_branches.md.erb` | 140 branches the corpus never walks | `stage150` output |
| `unreached_rules.md.erb` | 11 rules the corpus never reaches | `stage140` output |
| `with_latent.md.erb` | `with_latent:` coverage and the 24 excluded call sites | crate + #255's own list |

Two of these render their entire table from analysis output, so re-measuring
and rerunning updates the live issues rather than leaving them stale.

## Why the glob split comes first, alone

`script/generate_corpus_tests.rb` hardcodes a single local fixture file. The
audit stage puts 42 agents to work adding cases simultaneously, and every one
of them would append to that same JSON array. It is the identical problem
#163 already solved for the backend's source layout, and it takes the identical
answer: no central file, glob instead.

## Why `with_latent` is the expensive one

The other three add data. This one adds a checker to
`test/support/wafer_matchers.rb`, a flag to the fixture schema, and a fourth
reference time — a change to #255's generation pipeline. It is also the biggest
real hole: `with_latent:` is a public API parameter with **zero** corpus
coverage against 12 latent-producing rules.
