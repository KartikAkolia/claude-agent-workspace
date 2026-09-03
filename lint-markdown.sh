#!/usr/bin/env bash
# Lints this repo's own markdown with mdl and checks local cross-references
# for rot; validates tracked JSON/YAML config parses cleanly; and runs
# lint-bash.sh/lint-python.sh over this repo's own bash and Python scripts.
# The name predates the JSON/YAML/bash/Python checks -- kept as-is since
# .githooks/pre-commit and .github/workflows/lint.yml both call it by name
# and it's already the repo's one lint entry point, not just markdown.
# Skips the read-only ChrisTitusTech reference clones (see AGENTS.md
# non-negotiable #1).
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1

exclude_dirs=(dwm-titus-main linutil-main titus-ai-main website-master winutil-main)

pathspec=('*.md' ':!.*' ':!node_modules' ':!**/node_modules')
for dir in "${exclude_dirs[@]}"; do
	pathspec+=(":!$dir")
done
mapfile -t files < <(git ls-files "${pathspec[@]}")

config_pathspec=('*.json' '*.yml' '*.yaml' ':!node_modules' ':!**/node_modules')
for dir in "${exclude_dirs[@]}"; do
	config_pathspec+=(":!$dir")
done
mapfile -t config_files < <(git ls-files "${config_pathspec[@]}")

# Bash scripts aren't reliably *.sh (e.g. .githooks/pre-commit has no
# extension), so find them by shebang instead of extension.
all_pathspec=(':!node_modules' ':!**/node_modules')
for dir in "${exclude_dirs[@]}"; do
	all_pathspec+=(":!$dir")
done
mapfile -t all_files < <(git ls-files "${all_pathspec[@]}")
bash_files=()
for f in "${all_files[@]}"; do
	[ -f "$f" ] || continue
	IFS= read -r first_line <"$f" 2>/dev/null || continue
	case "$first_line" in
	'#!'*bash) bash_files+=("$f") ;;
	esac
done

python_pathspec=('*.py' ':!node_modules' ':!**/node_modules')
for dir in "${exclude_dirs[@]}"; do
	python_pathspec+=(":!$dir")
done
mapfile -t python_files < <(git ls-files "${python_pathspec[@]}")

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
