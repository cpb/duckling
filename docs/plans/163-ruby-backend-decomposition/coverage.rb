require "json"
crate = ARGV[0]; sdir = ARGV[1]

corpus = JSON.parse(File.read("#{sdir}/wafer_corpus.json"))["cases"]
local  = JSON.parse(File.read("#{sdir}/wafer_corpus_local.json")) rescue nil
local_cases = local.is_a?(Hash) ? (local["cases"] || []) : (local || [])
ALL = corpus + local_cases
TEXTS = ALL.map { |c| c["text"] }.compact
TIME_TEXTS = ALL.select { |c| c["file"].to_s.start_with?("time") || c["check"].to_s.start_with?("time", "no_time") }.map { |c| c["text"] }.compact

def rust_to_ruby(pat)
  p = pat.dup
  p = p.gsub("(?P<", "(?<")
  Regexp.new(p, Regexp::IGNORECASE)
rescue RegexpError => e
  [:error, e.message]
end

def extract_rules(path)
  src = File.read(path)
  lines = src.lines
  starts = []
  lines.each_with_index { |l, i| starts << i if l =~ /^\s{8}Rule \{\s*$/ }
  starts.each_with_index.map do |s, idx|
    e = starts[idx + 1] || lines.size
    block = lines[s...e].join
    name = block[/name:\s*"((?:[^"\\]|\\.)*)"/, 1]
    pat_section = block[/pattern:\s*vec!\[(.*?)\],\s*\n\s*production:/m, 1] || ""
    pats = []
    pat_section.scan(/r(#*)"(.*?)"\1[\s,)\]]/m) { |_h, body| pats << body }
    items = pat_section.scan(/\b(regex|predicate|dim)\s*\(/).flatten
    {name: name, line: s + 1, patterns: pats, items: items}
  end
end

def analyse(label, path, texts, out)
  extract_rules(path).each do |r|
    res = r[:patterns].map do |p|
      rx = rust_to_ruby(p)
      if rx.is_a?(Array)
        {pattern: p, status: "REGEX_ERROR", detail: rx[1], hits: 0}
      else
        hits = texts.count { |t| rx.match?(t) }
        {pattern: p, status: hits.zero? ? "NO_MATCH" : "ok", hits: hits}
      end
    end
    out << r.merge(dimension: label, results: res,
                   total_hits: res.sum { |x| x[:hits] },
                   any_error: res.any? { |x| x[:status] == "REGEX_ERROR" },
                   dead: !res.empty? && res.all? { |x| x[:hits].zero? })
  end
end

out = []
analyse("time", "#{crate}/src/dimensions/time/en.rs", TIME_TEXTS, out)
{"numeral" => "numeral", "duration" => "duration", "ordinal" => "ordinal", "time_grain" => "time_grain"}.each do |d, _|
  sub = ALL.select { |c| c["file"].to_s.include?(d.sub("time_grain", "time")) }.map { |c| c["text"] }.compact
  sub = TEXTS if sub.empty?
  analyse(d, "#{crate}/src/dimensions/#{d}/en.rs", d == "time_grain" ? TIME_TEXTS : sub, out)
end

File.write("#{sdir}/coverage.json", JSON.pretty_generate(out))
puts "corpus texts: all=#{TEXTS.size} time=#{TIME_TEXTS.size}"
puts "rules analysed: #{out.size}"
puts
out.group_by { |r| r[:dimension] }.each do |dim, rs|
  dead = rs.select { |r| r[:dead] && !r[:any_error] }
  err  = rs.select { |r| r[:any_error] }
  nopat = rs.select { |r| r[:patterns].empty? }
  puts format("%-11s rules=%3d  no-corpus-match=%3d  regex-translate-error=%2d  no-regex-item=%2d", dim, rs.size, dead.size, err.size, nopat.size)
end
