# Shared receipt-cached dependency installers for Claude Code Web sessions.
# Sourced (not executed) by bin/claude-code-web-setup (the Edit/Write
# PreToolUse hook) and bin/test (JIT setup for the bare `bundle exec rake`
# bash-run path, which Bash-only tool calls don't otherwise trigger a hook
# for). Both callers set CLAUDE_CODE_REMOTE-gating themselves before sourcing.

RECEIPTS_DIR="tmp/claude-web-receipts"
mkdir -p "$RECEIPTS_DIR"

# Ensures Ruby 3.4+ is the active Ruby before install_gems or
# compile_extension run. The gemspec floor will rise to >= 3.4.0 (parent
# issue), which makes bundle install fail on an older Ruby. This function
# provisions 3.4 by the cheapest available route and caches the selection
# in a receipt file so only the first call per session pays for it.
#
# The receipt file is a sourceable script: it holds export statements
# (PATH, RBENV_VERSION) that re-apply the selection on every subsequent
# call. bin/claude-code-web-setup is a fresh process each invocation and
# does not inherit the previous call's environment, so the receipt is
# what carries the selection forward within a session.
#
# Routes tried in cheapest-first order:
#   1. rbenv with an already-installed 3.4.x (zero install cost)
#   2. a ruby3.4 binary on PATH but not the default (zero install cost)
#   3. distro package via apt-get (fast, if the package exists)
#   4. rbenv + ruby-build source build (slowest, ~5 min)
#
# Routes 3 and 4 download from distro mirrors and cache.ruby-lang.org
# respectively, not GitHub. The sandbox blocks GitHub releases (the same
# constraint that keeps hk out), so routes that depend on GitHub (mise
# prebuilts) are not tried.
ensure_ruby() {
  local receipt
  receipt="$RECEIPTS_DIR/ruby-3.4"

  # Already on 3.4+ — nothing to do.
  if ruby -e 'exit(RUBY_VERSION >= "3.4.0" ? 0 : 1)' 2>/dev/null; then
    return 0
  fi

  # Already provisioned this session — re-apply the saved selection.
  if [ -f "$receipt" ]; then
    . "$receipt"
    return 0
  fi

  local start_time
  start_time=$(date +%s)

  # Route 1: rbenv with an already-installed 3.4.x.
  if command -v rbenv >/dev/null 2>&1; then
    local rbenv_ruby
    rbenv_ruby=$(rbenv versions --bare 2>/dev/null | grep '^3\.4' | sort -V | tail -1)
    if [ -n "$rbenv_ruby" ]; then
      printf 'export RBENV_VERSION=%s\n' "$rbenv_ruby" > "$receipt"
      . "$receipt"
      _ensure_bundle
      _log_cold_start "$start_time" "rbenv-select:$rbenv_ruby"
      return 0
    fi
  fi

  # Route 2: a ruby3.4 binary on PATH but not the default. The image may
  # carry both ruby3.3 and ruby3.4 packages.
  local ruby34
  ruby34=$(command -v ruby3.4 2>/dev/null || true)
  if [ -n "$ruby34" ]; then
    _select_suffixed_ruby "$ruby34" "$receipt"
    . "$receipt"
    _ensure_bundle
    _log_cold_start "$start_time" "ruby3.4-binary"
    return 0
  fi

  # Route 3: distro package. apt-get downloads from the distro mirror, not
  # GitHub, so it works under the sandbox's network restrictions.
  if command -v apt-get >/dev/null 2>&1; then
    if apt-get update -qq 2>/dev/null && apt-get install -y ruby3.4 2>/dev/null; then
      ruby34=$(command -v ruby3.4 2>/dev/null || echo /usr/bin/ruby3.4)
      _select_suffixed_ruby "$ruby34" "$receipt"
      . "$receipt"
      _ensure_bundle
      _log_cold_start "$start_time" "apt:ruby3.4"
      return 0
    fi
  fi

  # Route 4: rbenv + ruby-build source build. Downloads from
  # cache.ruby-lang.org, not GitHub, so it should work under the sandbox's
  # network restrictions. Slowest route (~5 min for a source build).
  if command -v rbenv >/dev/null 2>&1; then
    local latest_34
    latest_34=$(rbenv install --list 2>/dev/null | tr -d ' ' | grep '^3\.4' | sort -V | tail -1)
    if [ -n "$latest_34" ] && rbenv install "$latest_34" 2>/dev/null; then
      printf 'export RBENV_VERSION=%s\n' "$latest_34" > "$receipt"
      . "$receipt"
      _ensure_bundle
      _log_cold_start "$start_time" "rbenv-build:$latest_34"
      return 0
    fi
  fi

  echo "ensure_ruby: could not provision Ruby 3.4." >&2
  echo "  Current Ruby: $(ruby -v 2>&1)" >&2
  echo "  rbenv: $(command -v rbenv 2>/dev/null || echo 'not found')" >&2
  echo "  apt-get: $(command -v apt-get 2>/dev/null || echo 'not found')" >&2
  echo "  Install Ruby 3.4 manually or update the sandbox image." >&2
  return 1
}

# Creates a bin directory with symlinks that make `ruby` and `gem` resolve
# to the suffixed ruby3.4/gem3.4 binaries, then writes a PATH export to the
# receipt. This lets all subsequent commands (bundle, rake, etc.) use 3.4
# without needing to rename the system's default ruby.
_select_suffixed_ruby() {
  local ruby34_bin receipt bindir gem34
  ruby34_bin="$1"
  receipt="$2"
  bindir="$RECEIPTS_DIR/bin"
  mkdir -p "$bindir"
  ln -sf "$ruby34_bin" "$bindir/ruby"
  gem34=$(command -v gem3.4 2>/dev/null || true)
  [ -n "$gem34" ] && ln -sf "$gem34" "$bindir/gem"
  printf 'export PATH=%s:$PATH\n' "$bindir" > "$receipt"
}

_ensure_bundle() {
  if ! command -v bundle >/dev/null 2>&1; then
    gem install bundler
  fi
}

_log_cold_start() {
  local start route elapsed
  start="$1"
  route="$2"
  elapsed=$(( $(date +%s) - start ))
  printf '%s %s %ss\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$route" "$elapsed" \
    >> "$RECEIPTS_DIR/cold-start.log"
}

install_gems() {
  local lock_hash receipt
  lock_hash=$(sha256sum Gemfile.lock 2>/dev/null | cut -c1-8 || echo "no-lock")
  receipt="$RECEIPTS_DIR/gems-$lock_hash"

  [ -f "$receipt" ] && return 0

  bundle install
  touch "$receipt"
}

compile_extension() {
  local src_hash receipt
  src_hash=$(
    find ext/duckling -type f \( -name '*.rs' -o -name '*.toml' -o -name '*.lock' -o -name 'extconf.rb' \) \
      | sort \
      | xargs sha256sum \
      | sha256sum \
      | cut -c1-8
  )
  receipt="$RECEIPTS_DIR/ext-$src_hash"

  [ -f "$receipt" ] && return 0

  bundle exec rake compile
  touch "$receipt"
}
