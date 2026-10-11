# macOS lint toolchain for lint-*.sh, validate-config.sh and .githooks/pre-commit.
# Install with `brew bundle` from the repo root.

# The scripts use `mapfile` and expand possibly-empty arrays under `set -u`,
# neither of which works in macOS's stock /bin/bash 3.2. Their
# `#!/usr/bin/env bash` shebang picks this one up as long as Homebrew's bin
# dir is ahead of /bin on PATH (the default after `brew shellenv`).
brew "bash"

# lint-bash.sh
brew "shellcheck"
brew "shfmt"

# lint-python.sh runs ruff through `uvx`; the serena MCP server needs it too.
brew "uv"

# mdl (lint-markdown.sh) has no Homebrew formula and current releases don't
# support macOS's system ruby 2.6, so it's a gem on top of Homebrew's ruby:
#   "$(brew --prefix ruby)/bin/gem" install --no-document mdl --bindir ~/.local/bin
# (any bindir already on PATH works; the gem bin dir Homebrew's ruby defaults
# to, $(brew --prefix)/lib/ruby/gems/<version>/bin, isn't on PATH). Rerun it
# after a ruby minor-version bump, which moves the gem dir.
brew "ruby"
