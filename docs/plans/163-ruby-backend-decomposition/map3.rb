require "json"
crate = ARGV[0]
src = File.read("#{crate}/src/dimensions/time/en.rs")
lines = src.lines
starts = []
lines.each_with_index { |l, i| starts << i if l =~ /^\s{8}Rule \{\s*$/ }
rules = []
starts.each_with_index do |s, idx|
  e = starts[idx + 1] || lines.size
  block = lines[s...e].join
  name = block[/name:\s*"((?:[^"\\]|\\.)*)"/, 1]
  prod = block[/production:.*/m] || block
  built = prod.scan(/TimeData::(?:new|latent)\(\s*TimeForm::([A-Za-z]+)/).flatten
  built += ["Composed"] if prod =~ /\bcompose\(/ || prod =~ /intersect_dom\(/
  built += ["DateMDY"] if prod =~ /\bmonth_day\(/
  built += ["Hour/HourMinute(ampm)"] if prod =~ /apply_ampm\(/
  mods = []
  mods << "latent" if prod =~ /\.latent\s*=/
  mods << "early_late" if prod =~ /\.early_late\s*=/
  mods << "open_interval_direction" if prod =~ /\.open_interval_direction\s*=/
  mods << "timezone" if prod =~ /\.timezone\s*=/
  mods << "direction" if prod =~ /\.direction\s*=/
  mods << "ok_for_this_next" if prod =~ /\.ok_for_this_next\s*=/
  mods << "hour_ambiguity" if prod =~ /\.hour_(is_)?ambig/
  rules << {i: idx, name: name, line: s + 1, built: built.uniq, mods: mods}
end
File.write(ARGV[1], JSON.pretty_generate(rules))
by = Hash.new(0); rules.each { |r| (r[:built].empty? ? ["MODIFIER"] : r[:built]).each { |f| by[f] += 1 } }
by.sort_by { |k, v| -v }.each { |k, v| puts format("%-24s %3d", k, v) }
puts "---"
un = rules.select { |r| r[:built].empty? }
puts "modifier-only: #{un.size}"
un.each { |r| puts "  #{r[:line]}  #{r[:name]}  [#{r[:mods].join(",")}]" }
