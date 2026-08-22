require_relative "gh"
require "json"
I = ids
SL = JSON.parse(File.read(File.join(__dir__, "slices.json")))
GAPS = JSON.parse(File.read(File.join(__dir__, "gaps.json")), symbolize_names: true)
COV = JSON.parse(File.read(File.join(__dir__, "coverage.json")), symbolize_names: true)
A1, B1, B2, A2 = I.fetch("a1"), I.fetch("b1"), I.fetch("b2"), I.fetch("a2")
P2 = I["phase2"]; P3 = I["phase3"]; DM = I["dims"]; PARENT = I["phase3_parent"]

gapmap = {}
GAPS.each { |g| gapmap[g[:slice]] = g }

def known_block(g, b1, b2)
  return "_No gaps pre-identified for this slice by the regex sweep. That does not mean it is covered — see the caveat below._" if g.nil? || (g[:dead_rules].empty? && g[:branch_rules].empty? && g[:opaque].empty?)
  out = []
  unless g[:branch_rules].empty?
    out << "**Unexercised alternation branches — already ticketed in ##{b1}, do not duplicate:**\n\n" +
      g[:branch_rules].map { |name, br| "- `#{name.gsub("|", "\\|")}` → #{br.join(" · ")}" }.join("\n")
  end
  unless g[:dead_rules].empty?
    out << "**Rules no corpus case reaches — already ticketed in ##{b2}, do not duplicate:**\n\n" +
      g[:dead_rules].map { |n| "- `#{n.gsub("|", "\\|")}`" }.join("\n")
  end
  unless g[:opaque].empty?
    out << "**Rules the regex sweep cannot measure — THIS IS YOUR PRIMARY TARGET.** These have no regex item in their pattern (pure `predicate`/`dim` composition), so no automated method can tell whether the corpus exercises them. Only reading the Rust can:\n\n" +
      g[:opaque].map { |n| "- `#{n.gsub("|", "\\|")}`" }.join("\n")
  end
  out.join("\n\n")
end

SL.each do |s|
  key = s["key"]; slug = s["slug"]
  num = P3[key]; p2 = P2[key]
  lines = s["rules"].map { |r| r["line"] }.sort
  g = gapmap[key]
  read = if lines.empty?
    "`grep -n 'TimeForm::#{key}' src/dimensions/time/mod.rs` (#{s["mod_hits"]} references) — this variant has no rules of its own, so the whole audit is the resolver"
  elsif s["kind"] == "modifiers"
    "the #{s["rules"].size} modifier rules in `src/dimensions/time/en.rs` at lines #{lines.join(", ")}, plus every place `src/dimensions/time/mod.rs` reads `latent`, `early_late`, `open_interval_direction`, `timezone` or `direction` during resolution"
  else
    "the #{s["rules"].size} rule#{"s" unless s["rules"].size == 1} in `src/dimensions/time/en.rs` at line#{"s" unless lines.size == 1} #{lines.join(", ")}, plus every `TimeForm::#{key}` reference in `src/dimensions/time/mod.rs` (#{s["mod_hits"]}: `grep -n 'TimeForm::#{key}' src/dimensions/time/mod.rs`)"
  end
  label = key == "Modifiers" ? "modifier and absorption rules" : "TimeForm::#{key}"

  body = <<~MD
    Parent: ##{PARENT} · #163 · **Corpus audit — runs BEFORE the Ruby port, not after.**

    Blocked by ##{A1} only (the globbed local-fixture directory). Runs in parallel with all 41 sibling audits, with the corpus tickets ##{B1}/##{B2}/##{A2}, and with the spine ##{I["p0"]}.

    ## What changed, and why this is not Phase 3 any more

    This was going to run after Phase 2, comparing a finished Ruby backend against the native one. It now runs first. The corpus-growing half of the audit never needed the Ruby backend — it only needs the Rust and the native backend — and a gap found *before* the port is a gap the port never has. Finding it afterwards means an agent already wrote code against a spec that did not mention it.

    So there are **two outcomes here, not three**:

    | Result on the native backend | Meaning | Action |
    |---|---|---|
    | behaves as you predicted from the Rust | the corpus got stronger | keep the case — a standalone win for the corpus regardless of #163 |
    | behaves differently | either you misread the Rust, or it is an upstream bug the corpus was hiding | work out which. If upstream: record the divergence and file it against wafer-inc/duckling. **Do not pin surprising behaviour as golden without saying so** |

    The "fails on Ruby → port gap" outcome is gone, because there is no Ruby backend yet. That is the point.

    ## Read the Rust — that is the job here

    Read #{read}.

    The Phase 2 agent who later ports this slice (##{p2}) is forbidden from reading any of it. Everything in there that the corpus does not exercise is, right now, invisible to them. Your cases are the only thing that will make it visible.

    ## Already found for this slice — do not redo it

    A regex sweep over all 276 EN rules against #255's 1,662 texts has already been run. For this slice it found:

    #{known_block(g, B1, B2)}

    ## What to hunt for beyond that

    - `match` arms and `if let` branches in the **resolver** that no corpus text reaches — the sweep only sees rule patterns, never `mod.rs`
    - boundary values in the variant's fields the corpus only samples (`DayOfWeek` 0..6, `Month` 1..12, `DayOfMonth` 1..31, `Season` 0..3, negative `n`)
    - `Option` fields resolving to `None` where the corpus only ever supplies `Some` — `DateMDY`'s `year`, `Holiday`'s year
    - grain interactions: which `Grain` this variant reports, and how `early_late` or a `direction` changes it
    - rules whose pattern is pure `predicate`/`dim` composition, which the sweep cannot see at all

    ## Files you own

    - `test/fixtures/wafer_corpus_local/#{slug}.json` — **yours alone.** One file per audit agent is what makes 42 of these run at once; ##{A1} exists to allow it
    - regenerated files under `test/wafer/` (via `rake corpus:generate`, never hand-edited)

    Do **not** touch `test/fixtures/wafer_corpus.json` — `rake corpus:refresh` rewrites it wholesale from upstream and your cases would vanish.

    ## Definition of done

    - [ ] Every branch you identified either has a corpus case or a written note saying why it is unreachable
    - [ ] All cases in `test/fixtures/wafer_corpus_local/#{slug}.json`, expectations verified by hand against the native backend rather than merely recorded
    - [ ] Divergences from what the Rust says filed upstream, with links recorded here
    - [ ] `rake corpus:generate` clean, staleness test passing, full suite green
    - [ ] ##{p2} updated with a one-line note of what you added, so the porting agent knows their spec grew

    ## Caveat on the sweep

    A branch matching no corpus text is definitely unexercised. The converse does not hold — a branch that appears in some text may still never fire, because another rule can win the span. The list above is a lower bound, and a slice with an empty list is not a covered slice.
  MD

  bf = "/tmp/audit_#{num}.md"
  File.write(bf, body)
  sh("gh", "issue", "edit", num.to_s, "-R", REPO, "-t", "Corpus audit: #{label}", "-F", bf,
     "--add-label", "corpus-audit", "--remove-label", "phase-3")
  File.unlink(bf)
  puts "retargeted ##{num}  #{label}"
end
