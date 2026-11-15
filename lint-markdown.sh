#!/usr/bin/env bash
# Full local lint sweep of every tracked file list-lint-files.sh finds: mdl and check-markdown-links.py
# on markdown, validate-config.sh on JSON/YAML, lint-bash.sh and lint-python.sh on shell and Python.
set -uo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
# shellcheck source=/dev/null
source ./list-lint-files.sh || exit 1

status=0
markdown_files=() config_files=() bash_files=() python_files=()
for category in markdown config bash python; do
	llf_read_list "$category" "${category}_files" || status=1
done

py=""
for candidate in python3 python; do
	command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "" >/dev/null 2>&1 && py=$candidate && break
done
if ! command -v mdl >/dev/null 2>&1; then
	printf 'mdl not found on PATH (gem install --user-install mdl, then add the gem bin dir to PATH)\n' >&2
	status=1
elif [ -z "$py" ]; then
	printf 'no working python3/python interpreter found on PATH\n' >&2
	status=1
elif [ "${#markdown_files[@]}" -gt 0 ]; then
	mdl "${markdown_files[@]}" || status=1
	"$py" check-markdown-links.py "${markdown_files[@]}" || status=1
fi

./validate-config.sh "${config_files[@]}" || status=1
LINT_VERSIONS_MODE='' ./lint-bash.sh "${bash_files[@]}" || status=1
LINT_VERSIONS_MODE='' ./lint-python.sh "${python_files[@]}" || status=1

exit "$status"
