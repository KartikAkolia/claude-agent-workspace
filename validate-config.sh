#!/usr/bin/env bash
# Validates that JSON/YAML files parse cleanly -- nothing else catches a typo
# in .claude/settings.json or .serena/project.yml before it silently breaks
# hook/tool wiring at runtime. Takes file paths as arguments, like
# check-markdown-links.py, so both the pre-commit hook (staged files) and
# lint-markdown.sh/CI (all tracked files) can share this one script.
set -uo pipefail

if [ "$#" -eq 0 ]; then
	exit 0
fi

py=""
for candidate in python3 python; do
	if command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "" >/dev/null 2>&1; then
		py="$candidate"
		break
	fi
done

status=0
for f in "$@"; do
	case "$f" in
	*.json)
		if [ -z "$py" ]; then
			printf 'validate-config: no working python3/python interpreter found on PATH (needed for %s)\n' "$f" >&2
			status=1
			continue
		fi
		if ! "$py" -m json.tool "$f" >/dev/null; then
			printf 'validate-config: %s: invalid JSON\n' "$f" >&2
			status=1
		fi
		;;
	*.yml | *.yaml)
		if ! command -v ruby >/dev/null 2>&1; then
			printf 'validate-config: ruby not found on PATH (needed for %s)\n' "$f" >&2
			status=1
			continue
		fi
		if ! ruby -ryaml -e 'YAML.load_file(ARGV[0])' "$f" >/dev/null 2>&1; then
			printf 'validate-config: %s: invalid YAML\n' "$f" >&2
			status=1
		fi
		;;
	esac
done

exit "$status"
