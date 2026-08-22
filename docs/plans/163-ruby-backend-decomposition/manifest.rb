require "json"
crate = ARGV[0]
mod_src = File.read("#{crate}/src/dimensions/time/mod.rs")
enum = mod_src[/pub enum TimeForm \{.*?\n\}/m]

# split enum body into per-variant excerpts (comments above a variant belong to it)
body = enum.lines[1..-2]
variants = {}
buf = []
depth = 0
name = nil
body.each do |l|
  buf << l
  if depth.zero? && l =~ /^\s{4}([A-Z][A-Za-z]*)\s*(\{|\(|,)/
    name = $1
  end
  depth += l.count("{") - l.count("}")
  if name && depth.zero? && l =~ /(,|\},)\s*(\/\/.*)?$/
    variants[name] = buf.join.rstrip
    buf = []
    name = nil
  end
end

own = JSON.parse(File.read(ARGV[1]))
A = %w[DayOfWeek Month DayOfMonth Hour HourMinute HourMinuteSecond Year Now Today Tomorrow Yesterday DayAfterTomorrow DayBeforeYesterday RelativeGrain DateMDY PartOfDay Weekend Season Holiday GrainOffset NthGrain Quarter QuarterYear AllGrain RestOfGrain]
B = %w[BeginEnd NthDOWOfTime LastDOWOfTime LastCycleOfTime NDOWsFromTime NthGrainOfTime NthLastDayOfTime NthLastCycleOfTime DurationAfter]
Cw = %w[Interval Composed NthClosestToTime]

def slug(v) = v.gsub(/([a-z0-9])([A-Z])/, '\1_\2').gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2').downcase

slices = []
(A + B + Cw).each do |v|
  wave = A.include?(v) ? "A" : (B.include?(v) ? "B" : "C")
  slices << {
    key: v, slug: slug(v), wave: wave, kind: "time_form",
    excerpt: variants[v],
    mod_hits: mod_src.scan(/TimeForm::#{v}\b/).size,
    rules: (own[v] || []).map { |r| {name: r["name"], line: r["line"]} }
  }
end
slices << {key: "Modifiers", slug: "modifiers", wave: "A", kind: "modifiers", excerpt: nil, mod_hits: 0,
           rules: own["Modifiers"].map { |r| {name: r["name"], line: r["line"], mods: r["mods"]} }}
File.write(ARGV[2], JSON.pretty_generate(slices))
puts "slices=#{slices.size} rules=#{slices.sum { |s| s[:rules].size }}"
missing = slices.select { |s| s[:kind] == "time_form" && s[:excerpt].nil? }.map { |s| s[:key] }
puts "MISSING EXCERPT: #{missing.inspect}" unless missing.empty?
