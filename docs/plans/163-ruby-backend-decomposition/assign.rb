require "json"
rules = JSON.parse(File.read(ARGV[0]), symbolize_names: true)
A = %w[DayOfWeek Month DayOfMonth Hour HourMinute HourMinuteSecond Year Now Today Tomorrow Yesterday DayAfterTomorrow DayBeforeYesterday RelativeGrain DateMDY PartOfDay Weekend Season Holiday GrainOffset NthGrain Quarter QuarterYear AllGrain RestOfGrain]
B = %w[BeginEnd NthDOWOfTime LastDOWOfTime LastCycleOfTime NDOWsFromTime NthGrainOfTime NthLastDayOfTime NthLastCycleOfTime DurationAfter]
Cw = %w[Interval Composed NthClosestToTime]
rank = {}
A.each { |v| rank[v] = 1 }; B.each { |v| rank[v] = 2 }; Cw.each { |v| rank[v] = 3 }
own = Hash.new { |h, k| h[k] = [] }
rules.each do |r|
  b = r[:built].map { |f| f == "Hour/HourMinute(ampm)" ? "HourMinute" : f }.uniq
  if b.empty?
    own["Modifiers"] << r
  else
    winner = b.max_by { |f| [rank.fetch(f, 0), -A.index(f).to_i] }
    own[winner] << r
  end
end
puts "SLICE                       RULES"
(A + B + Cw + ["Modifiers"]).each { |v| puts format("%-26s %3d", v, own[v].size) }
puts "total=#{own.values.map(&:size).sum}"
File.write(ARGV[1], JSON.pretty_generate(own))
puts "\n--- Composed rules ---"; own["Composed"].each { |r| puts "  #{r[:name]}" }
puts "\n--- Interval rules ---"; own["Interval"].each { |r| puts "  #{r[:name]}" }
