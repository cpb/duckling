# frozen_string_literal: true

require_relative "lib/duckling/version"

Gem::Specification.new do |spec|
  spec.name = "duckling"
  spec.version = Duckling::VERSION
  spec.authors = ["Caleb Buxton"]
  spec.email = ["me@cpb.ca"]

  spec.summary = "Ruby FFI adapter to a Rust Duckling"
  spec.description = "Duckling NER without an HTTP service for Ruby"
  spec.homepage = "https://github.com/cpb/duckling"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2.0"
  spec.metadata["homepage_uri"] = spec.homepage
  spec.metadata["source_code_uri"] = "https://github.com/cpb/duckling"

  # Specify which files should be added to the gem when it is released.
  # The `git ls-files -z` loads the files in the RubyGem that have been added into git.
  gemspec = File.basename(__FILE__)
  spec.files = IO.popen(%w[git ls-files -z], chdir: __dir__, err: IO::NULL) do |ls|
    ls.readlines("\x0", chomp: true).reject do |f|
      (f == gemspec) ||
        f.start_with?(*%w[bin/ Gemfile .gitignore .env.local.example test/ .github/ .standard.yml hk.pkl])
    end
  end
  spec.bindir = "exe"
  spec.executables = spec.files.grep(%r{\Aexe/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.extensions = ["ext/duckling/extconf.rb"]

  # needed until rubygems supports Rust support is out of beta
  spec.add_dependency "rb_sys", "~> 0.9.39"

  # only needed when developing or packaging your gem
  spec.add_development_dependency "rake-compiler", "~> 1.3.1"
end
