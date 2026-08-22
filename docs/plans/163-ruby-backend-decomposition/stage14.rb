require_relative "gh"
require "json"

REPLACEMENTS = [
  # audit slice bodies (stage10/11)
  ["either you misread the Rust, or it is an upstream bug the corpus was hiding | work out which. If upstream: record the divergence and file it against wafer-inc/duckling. **Do not pin surprising behaviour as golden without saying so**",
   "either you misread the Rust, or it is an upstream bug the corpus was hiding | work out which. If it is a real divergence, open an `upstream-divergence` issue **on this repo** (see below). **Do not pin surprising behaviour as golden without saying so**"],
  ["you misread it, or it is an upstream bug the corpus was hiding | determine which; file upstream if it is a bug. **Never pin surprising behaviour as golden silently**",
   "you misread it, or it is an upstream bug the corpus was hiding | determine which; open an `upstream-divergence` issue **on this repo** if it is real (see below). **Never pin surprising behaviour as golden silently**"],
  ["- [ ] Divergences from what the Rust says filed upstream, with links recorded here",
   "- [ ] Divergences recorded as `upstream-divergence` issues on this repo, linked from here — see \"Upstream divergences\" in AGENTS.md"],
  ["- [ ] Divergences filed upstream, links recorded here",
   "- [ ] Divergences recorded as `upstream-divergence` issues on this repo, linked from here — see \"Upstream divergences\" in AGENTS.md"],
  # corpus tickets
  ["- [ ] Any case that does **not** behave as expected is an upstream finding: record it and file it against wafer-inc/duckling rather than pinning the surprising behaviour silently",
   "- [ ] Any case that does **not** behave as expected gets an `upstream-divergence` issue **on this repo**, not a silently pinned expectation — see \"Upstream divergences\" in AGENTS.md"],
  ["- [ ] Anything behaving unexpectedly is filed upstream against wafer-inc/duckling rather than pinned silently",
   "- [ ] Anything behaving unexpectedly gets an `upstream-divergence` issue **on this repo** rather than a silently pinned expectation — see \"Upstream divergences\" in AGENTS.md"],
  # parent
  ["- [ ] Native divergences recorded, with upstream issues filed against wafer-inc/duckling",
   "- [ ] Native divergences recorded as `upstream-divergence` issues on this repo — never filed against wafer-inc/duckling directly; see \"Upstream divergences\" in AGENTS.md"],
]

FOOTER = <<~MD

  ## Upstream divergences stay on this repo

  When the native backend disagrees with what the Rust source says, **open an issue here with the `upstream-divergence` label.** Do not open anything against wafer-inc/duckling.

  We accumulate these rather than filing them one at a time: a divergence found mid-audit is rarely fully understood yet, the same root cause often surfaces in several slices, and a batch that has been triaged makes a far better upstream report than a stream of individual guesses. Whether any of it ever goes upstream is a separate decision, taken later, by a human.

  Each such issue should carry the corpus case, what the Rust says should happen, what the native backend actually does, and the `en.rs`/`mod.rs` lines it comes from. See "Upstream divergences" in AGENTS.md.
MD

targets = sh("gh", "issue", "list", "-R", REPO, "--state", "open", "--limit", "200",
             "--json", "number,labels",
             "--jq", '.[]|select(.labels|map(.name)|any(.=="corpus" or .=="corpus-audit"))|.number').split.map(&:to_i).sort

targets.each do |n|
  body = sh("gh", "issue", "view", n.to_s, "-R", REPO, "--json", "body", "--jq", ".body")
  orig = body.dup
  REPLACEMENTS.each { |from, to| body = body.gsub(from, to) }
  body += FOOTER unless body.include?("Upstream divergences stay on this repo")
  if body == orig
    puts "  ##{n} unchanged"
    next
  end
  bf = "/tmp/up_#{n}.md"; File.write(bf, body)
  sh("gh", "issue", "edit", n.to_s, "-R", REPO, "-F", bf)
  File.unlink(bf)
  print "."
end
puts
puts "updated #{targets.size} issues"
