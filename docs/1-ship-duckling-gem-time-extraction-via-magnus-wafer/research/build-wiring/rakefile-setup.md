# Rakefile Setup

## Current Rakefile

Source: [`Rakefile`](https://github.com/cpb/duckling/blob/ec00708fc85e28ea510c3be4ce8df131497facb0/Rakefile)

```ruby
# frozen_string_literal: true

require "bundler/gem_tasks"
require "minitest/test_task"

Minitest::TestTask.create

require "standard/rake"

task default: %i[test standard]
```

No compile task and no `Rake::ExtensionTask`. Running `bundle exec rake` will
run tests (which will fail once `require "duckling/duckling"` is added to
lib files) and StandardRB lint only.

## Verified reference: rust_blank Rakefile

Source: [`examples/rust_blank/Rakefile`](https://github.com/matsadler/magnus/blob/4e46772050e47cd6cd988fa935263cc5c583e388/examples/rust_blank/Rakefile)

```ruby
# frozen_string_literal: true

require "rake/testtask"
require "rake/extensiontask"

task default: :test

Rake::ExtensionTask.new("rust_blank") do |c|
  c.lib_dir = "lib/rust_blank"
end

task :dev do
  ENV['RB_SYS_CARGO_PROFILE'] = 'dev'
end

Rake::TestTask.new do |t|
  t.deps << :dev << :compile
  t.test_files = FileList[File.expand_path("test/*_test.rb", __dir__)]
end
```

Key observations:
- `rake/extensiontask` is required (comes from the `rake-compiler` gem, which
  is pinned to `1.2.9` in Gemfile.lock)
- `Rake::ExtensionTask.new("rust_blank")` matches the gemspec extension name
- `c.lib_dir = "lib/rust_blank"` places the compiled `.so`/`.bundle` in
  `lib/rust_blank/` so that `require "rust_blank/rust_blank"` works
- The test task has `t.deps << :dev << :compile` — tests depend on compilation
- A `:dev` task sets `RB_SYS_CARGO_PROFILE = 'dev'` for faster debug builds

## Changes needed for the duckling Rakefile

Add after the existing requires:

```ruby
require "rake/extensiontask"

Rake::ExtensionTask.new("duckling") do |ext|
  ext.lib_dir = "lib/duckling"
end
```

The argument `"duckling"` to `ExtensionTask.new` must match the extension name
in `duckling.gemspec` — the gemspec declares
`spec.extensions = ["ext/duckling/extconf.rb"]`, and ExtensionTask derives the
shared library name from this.

Update the default task to include compilation:

```ruby
task default: %i[compile test standard]
```

## Why lib_dir = "lib/duckling"

`create_rust_makefile("duckling/duckling")` in extconf.rb tells rb_sys to put
the compiled library at the path `duckling/duckling` relative to `lib/`. That
resolves to `lib/duckling/duckling.bundle` (macOS) or
`lib/duckling/duckling.so` (Linux).

`Rake::ExtensionTask` needs to know this target directory so that when
`rake compile` runs, it moves the compiled artifact from the build staging area
into the correct location in `lib/`.

Setting `ext.lib_dir = "lib/duckling"` tells ExtensionTask that the output
belongs in `lib/duckling/`, which matches the extconf.rb path argument and
allows `require "duckling/duckling"` to find the file.

## Optional: dev task for faster iteration

Following the rust_blank pattern, a `:dev` task can be added to speed up the
edit-compile-test loop during development:

```ruby
task :dev do
  ENV["RB_SYS_CARGO_PROFILE"] = "dev"
end
```

Used as: `bundle exec rake dev compile test`

Without this, cargo defaults to the release profile (slower compile, faster
runtime). During development the dev profile is preferred.

## rake-compiler version

`rake-compiler` is a development dependency in gemspec:
`spec.add_development_dependency "rake-compiler", "~> 1.2.0"` and Gemfile.lock
pins it to `1.2.9`. `Rake::ExtensionTask` is provided by this gem.

## Resolved (were open questions)

1. **Does Minitest::TestTask.create support deps?** No need — the shipped
   Rakefile ([`main@03a69e1`](https://github.com/cpb/duckling/blob/03a69e157a1543862c734ca8ac278a84600af315/Rakefile))
   doesn't attempt to wire `Minitest::TestTask.create` with explicit deps at
   all. It relies purely on the `default` task's array ordering
   (`task default: %i[standard compile test]`), confirmed empirically below.
   Filed [issue #30](https://github.com/cpb/duckling/issues/30) to explore
   making `test` explicitly depend on `:compile` (`task test: :compile` or
   similar) so `bundle exec rake test` alone — not just the default task —
   also compiles first.

2. **Does `task default: %i[compile test standard]` guarantee compile runs
   before test?** Confirmed empirically with the installed Rake 13.4.2:

   ```ruby
   task :c do puts "RAN: c" end
   task :a do puts "RAN: a" end
   task :b do puts "RAN: b" end
   task default: %i[c a b]
   Rake::Task[:default].invoke
   # => RAN: c
   #    RAN: a
   #    RAN: b
   ```

   Rake invokes prerequisites in the array's listed order. `task default:
   %i[standard compile test]` (the shipped ordering) runs `standard` (lint),
   then `compile`, then `test`, in that order, every time.

## Follow-up: the `:dev` task was never added

The shipped Rakefile has no `:dev` task — `bundle exec rake compile` always
builds in the release Cargo profile (slower compile, faster runtime), even
during local development. Filed
[issue #31](https://github.com/cpb/duckling/issues/31) to add the
`RB_SYS_CARGO_PROFILE=dev` task described above for a faster edit-compile-test
loop.
