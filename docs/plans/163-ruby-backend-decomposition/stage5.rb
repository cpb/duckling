require_relative "gh"
require "json"
SL = JSON.parse(File.read(File.join(__dir__, "slices.json")))
I = ids
P2 = I.fetch("phase2"); DIMS = I.fetch("dims")

parent = create(
  title: "Ruby backend Phase 3 — gap audit (42 slices, mirrors Phase 2)",
  labels: %w[ruby-backend phase-3],
  body: <<~MD
    Parent: #163 · **Phase 3 — parallel swarm, starts once all of Phase 2 is green.**

    Sliced exactly as Phase 2 was. Each agent now **does** read its slice's Rust implementation, looking for branches the corpus never exercises, and writes new corpus cases for them.

    ## The three outcomes, and what each means

    Every new case runs against **both** backends:

    | Result | Meaning | Action |
    |---|---|---|
    | fails on Ruby | a port gap | fix the Ruby backend |
    | fails on native | an upstream bug the corpus was hiding | report it upstream and record the divergence in tree |
    | passes on both | the corpus got stronger | keep it — a standalone win for #157 |

    That third column is why Phase 3 is not optional cleanup. Phase 2's agents are forbidden from reading the Rust, so anything the corpus does not exercise is, by construction, unported and undetected. Phase 3 is the only thing that closes that.

    ## Why the audit is a separate phase rather than part of each slice

    Decision 2 of #163. If one agent both reads the Rust and writes the Ruby, the corpus stops being an independent oracle — the port and its test come from the same reading of the same source, and a misread produces a green test. Splitting the two phases across two agents is what keeps the differential honest.

    ## Definition of done

    - [ ] All 42 sub-issues closed
    - [ ] New cases merged into #157's corpus fixture, marked as local additions
    - [ ] Native divergences recorded in tree, with upstream issues filed against wafer-inc/duckling
    - [ ] Full corpus green on both backends
  MD
)
link(163, parent)
puts "Phase 3 parent = ##{parent}"

RUST_TIME = "src/dimensions/time"
created = {}

SL.each do |s|
  key = s["key"]; slug = s["slug"]; p2 = P2.fetch(key)
  lines = s["rules"].map { |r| r["line"] }.sort
  if s["kind"] == "modifiers"
    read = "the #{s["rules"].size} modifier rules in `#{RUST_TIME}/en.rs` at lines #{lines.join(", ")}, plus the `TimeData` attribute fields (`latent`, `early_late`, `open_interval_direction`, `timezone`, `direction`, `ok_for_this_next`) and every place `#{RUST_TIME}/mod.rs` reads them during resolution"
    hunt = <<~MD
      Attribute-mutating rules are the easiest place for an unexercised branch to hide, because the corpus asserts on the *resolved value*, not on the intermediate flags. Specific things to look for:

      - keyword alternations where only some branches appear in the corpus — `until|through|before|since|after|from|anytime after|sometimes before` is one regex with eight branches and the corpus does not exercise all eight
      - `latent` promotion paths that no corpus case reaches, so a latent token stays latent on the Ruby side and silently produces no entity
      - the `EarlyLate::Mid` branch, and `direction` on `<time> before last|after next`
      - timezone abbreviations in the `<time> timezone` alternation with no corpus case
    MD
  else
    read = if lines.empty?
      "`grep -n 'TimeForm::#{key}' #{RUST_TIME}/mod.rs` (#{s["mod_hits"]} references) — this variant has no rules of its own, so the whole audit is the resolver"
    else
      "the #{s["rules"].size} rule#{"s" unless s["rules"].size == 1} in `#{RUST_TIME}/en.rs` at line#{"s" unless lines.size == 1} #{lines.join(", ")}, plus every `TimeForm::#{key}` reference in `#{RUST_TIME}/mod.rs` (#{s["mod_hits"]} of them: `grep -n 'TimeForm::#{key}' #{RUST_TIME}/mod.rs`)"
    end
    hunt = <<~MD
      - regex alternation branches with no corpus case behind them
      - `match` arms and `if let` branches in the resolver that no fixture row reaches
      - boundary values: the `u32`/`i32` fields in the variant have ranges the corpus may only sample (`DayOfWeek` 0..6, `Month` 1..12, `DayOfMonth` 1..31, `Season` 0..3, negative `n`)
      - `Option` fields resolving to `None` — `DateMDY`'s `year`, `Holiday`'s year — where the corpus only ever supplies `Some`
      - grain interactions: which `Grain` this variant reports, and how that changes under `early_late` or a `direction`
    MD
  end

  body = <<~MD
    Parent: ##{parent} · #163 Phase 3 · gap audit for slice **`#{key}`**

    Mirrors ##{p2}. Starts once **all** of Phase 2 is green — not just ##{p2}, because a gap here can surface as a failure in a neighbouring slice.

    ## Read the Rust — this is the phase where that is the job

    Read #{read}.

    ##{p2}'s agent was forbidden from reading any of it. Everything in there that the corpus does not exercise is, by construction, unported and undetected right now. Your job is to find it.

    ## What to hunt for

    #{hunt}
    ## For each gap found, write a corpus case and run it on both backends

    | Result | Meaning | Action |
    |---|---|---|
    | fails on Ruby | a port gap | fix the Ruby backend — you may edit `#{s["kind"] == "modifiers" ? "lib/duckling/ruby/rules/en/modifiers.rb" : "lib/duckling/ruby/{time/forms,rules/en}/#{slug}.rb"}` |
    | fails on native | an upstream bug the corpus was hiding | record the divergence and file it against wafer-inc/duckling; do **not** make the Ruby backend match the bug without saying so |
    | passes on both | the corpus got stronger | keep it — a standalone win for #157 |

    ## Definition of done

    - [ ] Every branch identified above either has a corpus case or a written note saying why it is unreachable
    - [ ] New cases added to #157's corpus fixture, clearly marked as local additions
    - [ ] All new cases green on the Ruby backend, or the divergence is recorded with an upstream issue link
    - [ ] Full suite green on both backends
    - [ ] Still no file outside this slice's own four modified

    ## Scope discipline

    You own the same files ##{p2} owned and nothing else. A gap that turns out to live in the spine is a follow-up issue against ##{ids.fetch("p0")}'s output, not an edit here.
  MD

  num = create(title: "Ruby backend Phase 3 — gap audit: #{key == "Modifiers" ? "modifier and absorption rules" : "TimeForm::#{key}"}", body: body, labels: %w[ruby-backend phase-3])
  link(parent, num)
  created[key] = num
  puts "audit #{key} -> ##{num}"
end

DIMNOTE = {
  "numeral" => "numeral", "duration" => "duration", "ordinal" => "ordinal", "time_grain" => "time_grain"
}
DIMS.each do |slug, p2|
  body = <<~MD
    Parent: ##{parent} · #163 Phase 3 · gap audit for the **#{slug}** dependency dimension

    Mirrors ##{p2}. Starts once all of Phase 2 is green.

    ## Read the Rust — this is the phase where that is the job

    Read `src/dimensions/#{slug}/en.rs` and `src/dimensions/#{slug}/mod.rs` in full (duckling 0.4.0). ##{p2}'s agent was forbidden from reading either.

    ## What to hunt for

    - regex alternation branches with no corpus case behind them — spelled-out forms, abbreviations, and separator variants are the usual gaps
    - `match` arms and `if let` branches in the value construction that no fixture row reaches
    - boundary and sign handling: negatives, zero, very large values, decimal/thousands separators
    - value-shape fields the corpus never asserts on, which would let a wrong shape pass

    ## For each gap found, write a corpus case and run it on both backends

    | Result | Meaning | Action |
    |---|---|---|
    | fails on Ruby | a port gap | fix the Ruby backend |
    | fails on native | an upstream bug the corpus was hiding | record the divergence and file it against wafer-inc/duckling |
    | passes on both | the corpus got stronger | keep it — a standalone win for #157 |

    ## Definition of done

    - [ ] Every branch identified either has a corpus case or a written note saying why it is unreachable
    - [ ] New cases added to #157's corpus fixture, marked as local additions
    - [ ] All new cases green on the Ruby backend, or the divergence is recorded with an upstream issue link
    - [ ] Full suite green on both backends
    - [ ] You own only ##{p2}'s files
  MD
  num = create(title: "Ruby backend Phase 3 — gap audit: #{slug} dimension", body: body, labels: %w[ruby-backend phase-3])
  link(parent, num)
  created["dim:#{slug}"] = num
  puts "audit #{slug} -> ##{num}"
end

h = ids; h["phase3_parent"] = parent; h["phase3"] = created
File.write(File.join(__dir__, "created.json"), JSON.pretty_generate(h))
