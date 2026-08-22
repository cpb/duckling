require_relative "gh"
require "json"
I = ids
GAPS = JSON.parse(File.read(File.join(__dir__, "gaps.json")), symbolize_names: true)
A1, B1, B2, A2 = I.fetch("a1"), I.fetch("b1"), I.fetch("b2"), I.fetch("a2")
DM = I["dims"]; P3 = I["phase3"]; PARENT = I["phase3_parent"]
gapmap = {}; GAPS.each { |g| gapmap[g[:slice]] = g }

DM.each do |slug, p2|
  num = P3["dim:#{slug}"]
  g = gapmap["dim:#{slug}"]
  known = if g.nil? || (g[:dead_rules].empty? && g[:branch_rules].empty? && g[:opaque].empty?)
    "_Nothing pre-identified by the regex sweep for this dimension._"
  else
    parts = []
    parts << "**Unexercised branches — ticketed in ##{B1}, do not duplicate:**\n\n" + g[:branch_rules].map { |n, br| "- `#{n.gsub("|", "\\|")}` → #{br.join(" · ")}" }.join("\n") unless g[:branch_rules].empty?
    parts << "**Rules no corpus case reaches — ticketed in ##{B2}, do not duplicate:**\n\n" + g[:dead_rules].map { |n| "- `#{n.gsub("|", "\\|")}`" }.join("\n") unless g[:dead_rules].empty?
    parts << "**Rules the sweep cannot measure — YOUR PRIMARY TARGET** (pure `predicate`/`dim` patterns, no regex to test):\n\n" + g[:opaque].map { |n| "- `#{n.gsub("|", "\\|")}`" }.join("\n") unless g[:opaque].empty?
    parts.join("\n\n")
  end

  body = <<~MD
    Parent: ##{PARENT} · #163 · **Corpus audit — runs BEFORE the Ruby port.**

    Blocked by ##{A1} only. Runs in parallel with all 41 sibling audits, with ##{B1}/##{B2}/##{A2}, and with the spine ##{I["p0"]}.

    ## Two outcomes, not three

    There is no Ruby backend yet — that is the point of moving this earlier. A gap found now is a gap the port never has.

    | Result on the native backend | Meaning | Action |
    |---|---|---|
    | behaves as you predicted from the Rust | the corpus got stronger | keep the case |
    | behaves differently | you misread it, or it is an upstream bug the corpus was hiding | determine which; file upstream if it is a bug. **Never pin surprising behaviour as golden silently** |

    ## Read the Rust

    Read `src/dimensions/#{slug}/en.rs` and `src/dimensions/#{slug}/mod.rs` in full (duckling 0.4.0). The Phase 2 agent who ports this dimension (##{p2}) is forbidden from reading either.

    ## Already found — do not redo it

    #{known}

    ## What to hunt for beyond that

    - alternation branches with no corpus case — spelled-out forms, abbreviations, separator variants
    - `match` arms and `if let` branches in value construction that no case reaches
    - boundary and sign handling: negatives, zero, very large values, decimal and thousands separators
    - value-shape fields the corpus never asserts on, which would let a wrong shape pass
    - rules with pure `predicate`/`dim` patterns, which no automated sweep can see

    ## Files you own

    - `test/fixtures/wafer_corpus_local/#{slug}.json` — yours alone; ##{A1} is what makes that possible
    - regenerated `test/wafer/` output via `rake corpus:generate`

    Never touch `test/fixtures/wafer_corpus.json` — `corpus:refresh` rewrites it from upstream.

    ## Definition of done

    - [ ] Every branch identified has a case, or a written note saying why it is unreachable
    - [ ] Expectations verified by hand against the native backend
    - [ ] Divergences filed upstream, links recorded here
    - [ ] `rake corpus:generate` clean, staleness test passing, suite green
    - [ ] ##{p2} updated with a one-line note that its spec grew
  MD
  bf = "/tmp/audit_#{num}.md"; File.write(bf, body)
  sh("gh", "issue", "edit", num.to_s, "-R", REPO, "-t", "Corpus audit: #{slug} dimension", "-F", bf,
     "--add-label", "corpus-audit", "--remove-label", "phase-3")
  File.unlink(bf)
  puts "retargeted ##{num}  #{slug}"
end

# parent
pbody = <<~MD
  Parent: #163 · **Corpus audit — 42 slices, running BEFORE the Ruby port.**

  Blocked by ##{A1}. Runs in parallel with the spine (##{I["p0"]}), the ranking layer (##{I["rank"]}), and the three corpus tickets ##{B1} / ##{B2} / ##{A2}. **Blocks Phase 1 fixture capture (##{I["p1"]})**, and through it all of Phase 2.

  ## What changed

  This was Phase 3: a swarm that ran *after* Phase 2, comparing a finished Ruby backend against the native one. It now runs first, and it is a corpus stage rather than a port stage.

  The corpus-growing half of the audit never needed the Ruby backend. It needs the Rust and the native backend, both of which exist today. Running it first inverts the economics:

  | | Audit after the port | Audit before the port |
  |---|---|---|
  | A gap in the corpus | is found after 42 agents already ported against a spec missing it | never reaches the porting agent |
  | Fixing it | means re-opening a merged slice | means the slice was right the first time |
  | An upstream bug | surfaces as a confusing three-way disagreement | surfaces cleanly against one backend |

  What is lost is the third outcome — "fails on Ruby, so it is a port gap". That outcome only exists because the case arrived too late. Preventing it is strictly better than diagnosing it.

  ## The residual differential still happens

  It just is not a 42-way swarm any more. Running the grown corpus against both backends is ##{I["phase4"]["ci"]}, which was always going to do exactly that in CI. A slice that mis-ports something the corpus now covers fails there.

  ## What the sweep already found

  A regex sweep over all 276 EN rules against #255's 1,662 texts, before any of these agents start:

  - **140 unexercised literal alternation branches** across 23 rules → ##{B1}
  - **11 rules no corpus text reaches at all** → ##{B2}
  - **zero `with_latent:` coverage** against 12 latent-producing rules → ##{A2}
  - **27 rules with no regex item**, which no sweep can measure — these are the swarm's primary target, and they are listed per-slice in each sub-issue

  Each sub-issue carries its own slice's findings so no agent redoes that work.

  ## Definition of done

  - [ ] All 42 sub-issues closed
  - [ ] Cases live in `test/fixtures/wafer_corpus_local/<slice>.json`, one file per slice
  - [ ] Native divergences recorded, with upstream issues filed against wafer-inc/duckling
  - [ ] Full suite green, `rake corpus:generate` clean
  - [ ] The grown corpus is what ##{I["p1"]} then captures fixtures from
MD
File.write("/tmp/parent.md", pbody)
sh("gh", "issue", "edit", PARENT.to_s, "-R", REPO,
   "-t", "Corpus audit — 42 slices, before the Ruby port (was Phase 3)",
   "-F", "/tmp/parent.md", "--add-label", "corpus-audit", "--remove-label", "phase-3")
puts "retargeted parent ##{PARENT}"
