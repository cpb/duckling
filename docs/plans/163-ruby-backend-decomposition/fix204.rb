require_relative "gh"
b = sh("gh", "issue", "view", "204", "-R", REPO, "--json", "body", "--jq", ".body")
b = b.sub(
  "**Wave A — leaf variant, no `TimeData` child.** Fully parallel with every other Wave A slice and with the four dependency-dimension slices. No ordering constraint of any kind inside the wave.",
  "**Wave A — cross-cutting, no variant of its own.** Fully parallel with every other Wave A slice and with the four dependency-dimension slices. These rules run *after* a `TimeData` already exists, but they need no resolver, so they carry no wave dependency."
)
b = b.sub(
  "- `lib/duckling/ruby/time/forms/modifiers.rb` — the resolver, self-registering under its variant tag\n",
  ""
)
b = b.sub(
  "**Files you create. No other slice touches them:**",
  "**Files you create. No other slice touches them.** There is no `time/forms/` file here — this slice adds no `TimeForm` and therefore no resolver:"
)
File.write("/tmp/b204.md", b)
sh("gh", "issue", "edit", "204", "-R", REPO, "-F", "/tmp/b204.md")
puts "patched #204"
