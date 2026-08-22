require "json"
REPO = "cpb/duckling"

def sh(*a)
  out = IO.popen(a, err: [:child, :out], &:read)
  raise "FAILED: #{a.join(" ")}\n#{out}" unless $?.success?
  out
end

def create(title:, body:, labels:)
  bf = "/tmp/ghbody_#{Process.pid}.md"
  File.write(bf, body)
  url = sh("gh", "issue", "create", "-R", REPO, "-t", title, "-F", bf, "-l", labels.join(",")).lines.grep(%r{https://}).last.strip
  num = url[%r{/(\d+)\z}, 1].to_i
  File.unlink(bf)
  num
end

def dbid(num)
  sh("gh", "api", "repos/#{REPO}/issues/#{num}", "--jq", ".id").strip.to_i
end

def link(parent, child)
  sh("gh", "api", "repos/#{REPO}/issues/#{parent}/sub_issues", "-F", "sub_issue_id=#{dbid(child)}")
end

def record(key, num)
  path = File.join(__dir__, "created.json")
  h = File.exist?(path) ? JSON.parse(File.read(path)) : {}
  h[key] = num
  File.write(path, JSON.pretty_generate(h))
end

def ids
  path = File.join(__dir__, "created.json")
  File.exist?(path) ? JSON.parse(File.read(path)) : {}
end
