#!/usr/bin/env bash
# Lints this repo's own markdown with mdl and checks local cross-references
# for rot; validates tracked JSON/YAML config parses cleanly; and runs
# lint-bash.sh/lint-python.sh over this repo's own bash and Python scripts.
# The name predates the JSON/YAML/bash/Python checks -- kept as-is since
# .githooks/pre-commit calls it by name for a full local sweep. CI no longer
# calls this directly: it's split into four path-filtered
# .github/workflows/lint-*.yml files instead (2026-09-03), so e.g. a
# markdown-only change doesn't also trigger the bash/Python/config checks.
# This script is still useful as the "run every category at once" entry
# point for a full local check. File discovery for each category lives in
# list-lint-files.sh, shared with those CI workflows. Skips the read-only
# ChrisTitusTech reference clones (see AGENTS.md non-negotiable #1).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

mapfile -t files < <(./list-lint-files.sh markdown)
mapfile -t config_files < <(./list-lint-files.sh config)
mapfile -t bash_files < <(./list-lint-files.sh bash)
mapfile -t python_files < <(./list-lint-files.sh python)

status=0

if ! command -v mdl >/dev/null 2>&1; then
	printf 'mdl not found on PATH (gem install --user-install mdl, then add the gem bin dir to PATH)\n' >&2
	status=1
else
	# Don't trust check-markdown-links.py's own `#!/usr/bin/env python3` shebang --
	# on Windows, `python3` often resolves to the broken App Execution Alias stub
	# (prints an "install from the Microsoft Store" message and exits nonzero)
	# instead of a real interpreter, even when python3/python is genuinely
	# installed under a different PATH entry. Pick whichever name actually runs.
	py=""
	for candidate in python3 python; do
		if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "" >/dev/null 2>&1; then
			py="$candidate"
			break
		fi
	done
	if [ -z "$py" ]; then
		printf 'no working python3/python interpreter found on PATH\n' >&2
		status=1
	else
		mdl "${files[@]}" || status=1
		"$py" check-markdown-links.py "${files[@]}" || status=1
	fi
fi

./validate-config.sh "${config_files[@]}" || status=1
./lint-bash.sh "${bash_files[@]}" || status=1
./lint-python.sh "${python_files[@]}" || status=1

exit "$status"
