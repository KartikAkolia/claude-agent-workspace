#!/usr/bin/env bash
# Checks that the given JSON and YAML files parse cleanly: JSON with python -m json.tool, every YAML
# document with Ruby's Psych, aliases allowed and only plain types, dates and symbols loaded.
# Docs: docs/repo-tooling.md
set -uo pipefail

[ "$#" -gt 0 ] || exit 0

py=""
for candidate in python3 python; do
	command -v "$candidate" >/dev/null 2>&1 && "$candidate" -c "" >/dev/null 2>&1 && py=$candidate && break
done

status=0
for f in "$@"; do
	if [[ $f == *.json && -z $py ]]; then
		printf 'validate-config: no working python3/python interpreter found on PATH (needed for %s)\n' "$f" >&2
		status=1
	elif [[ $f == *.json ]] && ! "$py" -m json.tool "$f" >/dev/null; then
		printf 'validate-config: %s: invalid JSON\n' "$f" >&2
		status=1
	elif [[ $f == *.yml || $f == *.yaml ]] && ! command -v ruby >/dev/null 2>&1; then
		printf 'validate-config: ruby not found on PATH (needed for %s)\n' "$f" >&2
		status=1
	elif [[ $f == *.yml || $f == *.yaml ]] && ! ruby -ryaml -rdate -e 'begin
		loader = Psych::ClassLoader::Restricted.new(%w[Date DateTime Time Symbol], [])
		scanner = Psych::ScalarScanner.new(loader)
		Psych.parse_stream(File.read(ARGV[0]), filename: ARGV[0]).children.each do |doc|
			Psych::Visitors::ToRuby.new(scanner, loader).accept(doc)
		end
	rescue Psych::Exception => e
		warn "#{ARGV[0]}: #{e.message}"
		exit 1
	end' "$f"; then
		printf 'validate-config: %s: invalid YAML\n' "$f" >&2
		status=1
	fi
done

exit "$status"
