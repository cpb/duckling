# stage250 — create corpus audits

The audit parent plus one audit issue per slice: 43 issues.

| Template | Renders |
|---|---|
| `audit_parent.md.erb` | why the audit moved ahead of the port, and what the sweep already found |
| `audit_slice.md.erb` | one per slice: what to read, what is already ticketed, what to hunt |

## The inversion this stage encodes

These were originally Phase 3 — a swarm running *after* Phase 2, comparing a
finished Ruby backend against the native one. They now run first.

The corpus-growing half of an audit never needed the Ruby backend. It needs the
Rust and the native backend, both of which exist today. Running it first means
a gap is closed before any agent ports against a spec missing it, instead of
after. The outcome that disappears — "fails on Ruby, so it is a port gap" —
only existed because the case arrived too late.

Decision 2's oracle property survives, because it rests on *different agents*
doing the reading and the porting, not on the ordering. Phase 2 agents still
never read the Rust; they just get a denser spec.

## Line numbers appear here and nowhere else

An audit issue names the exact `en.rs` lines and `mod.rs` references to read.
The corresponding Phase 2 issue lists rule *names* only. That asymmetry is
deliberate: this is the phase whose job is reading the source, and that one is
forbidden from it.

## Each issue carries its own findings

`known_blocks` splits a slice's pre-identified gaps into "already ticketed in
stage240, do not duplicate" and "the sweep cannot see these, they are yours".
The second group — rules with pure `predicate`/`dim` patterns — is the real
target, because no automated method can check them.
