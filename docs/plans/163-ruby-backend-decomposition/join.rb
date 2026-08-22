require "json"
sl  = JSON.parse(File.read("#{ARGV[0]}/slices.json"))
ids = JSON.parse(File.read("#{ARGV[0]}/created.json"))
cov = JSON.parse(File.read("#{ARGV[0]}/coverage.json"), symbolize_names: true)
db  = JSON.parse(File.read("#{ARGV[0]}/dead_branches.json"), symbolize_names: true)

# time rule line -> slice key
line2slice = {}
sl.each { |s| s["rules"].each { |r| line2slice[r["line"]] = s["key"] } }

dbh = {}; db.each { |r| dbh[[r[:dimension], r[:line]]] = r[:dead_branches] }

rows = Hash.new { |h, k| h[k] = {dead_rules: [], branch_rules: [], opaque: [], branches: 0} }
cov.each do |r|
  slice = r[:dimension] == "time" ? (line2slice[r[:line]] || "??") : "dim:#{r[:dimension]}"
  rec = rows[slice]
  rec[:dead_rules] << r[:name] if r[:dead] && !r[:any_error]
  rec[:opaque] << r[:name] if r[:patterns].empty?
  if (b = dbh[[r[:dimension], r[:line]]])
    rec[:branch_rules] << [r[:name], b]
    rec[:branches] += b.size
  end
end

def ticket(ids, slice)
  return ids["dims"][slice.sub("dim:", "")] if slice.start_with?("dim:")
  ids["phase2"][slice]
end
def audit(ids, slice)
  return ids["phase3"]["dim:#{slice.sub("dim:", "")}"] if slice.start_with?("dim:")
  ids["phase3"][slice]
end

scored = rows.map { |slice, v|
  score = v[:dead_rules].size * 3 + v[:branches] + v[:opaque].size * 2
  [slice, v, score]
}.sort_by { |_, _, s| -s }

puts format("%-22s %-6s %-6s %6s %8s %7s", "SLICE", "P2", "P3", "dead", "branches", "opaque")
scored.each do |slice, v, score|
  next if score.zero?
  puts format("%-22s #%-5s #%-5s %6d %8d %7d", slice, ticket(ids, slice), audit(ids, slice), v[:dead_rules].size, v[:branches], v[:opaque].size)
end
puts
puts "slices with ZERO detected gaps: #{rows.count { |_, v| v[:dead_rules].empty? && v[:branches].zero? && v[:opaque].empty? }} of #{rows.size}"
File.write("#{ARGV[0]}/gaps.json", JSON.pretty_generate(scored.map { |s, v, sc| {slice: s, p2: ticket(ids, s), p3: audit(ids, s), score: sc}.merge(v) }))
