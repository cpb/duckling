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

## Open Questions

1. **Does Minitest::TestTask.create support deps?** The current Rakefile uses
   `Minitest::TestTask.create` (minitest 6.0.6). The rust_blank example uses
   `Rake::TestTask` with `t.deps << :compile`. These are different classes.
   Check whether `Minitest::TestTask.create` accepts a block with deps, or
   whether the compile task needs to be listed explicitly in the default task
   ordering.

2. **Does `task default: %i[compile test standard]` guarantee compile runs
   before test?** Rake executes prerequisite tasks in left-to-right order when
   they are listed in the array, so `compile` running before `test` should hold.
   Verify against actual Rake behavior with the installed rake version (13.4.2).
