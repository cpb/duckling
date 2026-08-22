require "json"
crate = ARGV[0]; sdir = ARGV[1]
cov = JSON.parse(File.read("#{sdir}/coverage.json"), symbolize_names: true)
corpus = JSON.parse(File.read("#{sdir}/wafer_corpus.json"))["cases"]
local = JSON.parse(File.read("#{sdir}/wafer_corpus_local.json")) rescue {}
lc = local.is_a?(Hash) ? (local["cases"] || []) : local
ALL = corpus + lc
TEXTS = ALL.map { |c| c["text"] }.compact.map(&:downcase)

# split a regex body on top-level alternation
def split_alts(s)
  out = []; depth = 0; cls = false; esc = false; cur = +""
  s.each_char do |ch|
    if esc then cur << ch; esc = false; next end
    case ch
    when "\\" then cur << ch; esc = true
    when "[" then cls = true; cur << ch
    when "]" then cls = false; cur << ch
    when "(" then depth += 1 unless cls; cur << ch
    when ")" then depth -= 1 unless cls; cur << ch
    when "|"
      if depth.zero? && !cls then out << cur; cur = +"" else cur << ch end
    else cur << ch
    end
  end
  out << cur
  out
end

# find groups containing top-level alternations, return [branch, ...]
def alt_branches(pat)
  branches = []
  stack = []
  i = 0; cls = false
  while i < pat.length
    ch = pat[i]
    if ch == "\\" then i += 2; next end
    cls = true if ch == "[" && !cls
    cls = false if ch == "]" && cls
    unless cls
      if ch == "(" then stack << i
      elsif ch == ")" && !stack.empty?
        st = stack.pop
        body = pat[(st + 1)...i]
        body = body.sub(/\A\?:/, "").sub(/\A\?P?<[^>]*>/, "").sub(/\A\?[imsx-]*:/, "")
        parts = split_alts(body)
        branches.concat(parts) if parts.size > 1
      end
    end
    i += 1
  end
  # also top-level alternation of the whole pattern
  top = split_alts(pat)
  branches.concat(top) if top.size > 1
  branches
end

LITERAL = /\A[a-z0-9 .'\-]+\z/i
report = []
cov.each do |r|
  next if r[:patterns].empty?
  dead_branches = []
  r[:patterns].each do |p|
    alt_branches(p).each do |b|
      b = b.strip
      next unless b =~ LITERAL           # only literal branches — skip regex-y ones
      next if b.length < 2
      probe = b.gsub(/[.\-']/) { |m| "\\" + m }
      next if TEXTS.any? { |t| t.match?(/#{probe}/i) }
      dead_branches << b
    end
  end
  dead_branches.uniq!
  report << r.slice(:name, :line, :dimension).merge(dead_branches: dead_branches) unless dead_branches.empty?
end

File.write("#{sdir}/dead_branches.json", JSON.pretty_generate(report))
total = report.sum { |r| r[:dead_branches].size }
puts "rules with >=1 unexercised literal alternation branch: #{report.size}"
puts "total unexercised literal branches: #{total}"
puts
report.group_by { |r| r[:dimension] }.each { |d, rs| puts format("  %-11s %3d rules, %3d branches", d, rs.size, rs.sum { |r| r[:dead_branches].size }) }
