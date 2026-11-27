#!/usr/bin/env bash
# Combine the per-page PDFs into one book, in urls.txt crawl order. A URL with
# no non-empty PDF stops the merge unless --allow-missing is given.
# Docs: docs/mathsisfun-pdf-scrape.md
set -euo pipefail

usage() {
	printf 'usage: %s [--allow-missing] [urls.txt] [pdf_dir] [combined.pdf]\n' "${0##*/}"
}

allow_missing=0
while [ "$#" -gt 0 ]; do
	case $1 in
	--allow-missing)
		allow_missing=1
		shift
		;;
	-h | --help)
		usage
		exit 0
		;;
	--)
		shift
		break
		;;
	-*)
		usage >&2
		exit 2
		;;
	*) break ;;
	esac
done
if [ "$#" -gt 3 ]; then
	usage >&2
	exit 2
fi

urls_file="${1:-urls.txt}"
pdf_dir="${2:-pdfs}"
combined="${3:-algebra-mathsisfun.pdf}"

command -v pdfunite >/dev/null 2>&1 || {
	echo "pdfunite not found in PATH (poppler-utils)" >&2
	exit 1
}
[ -r "$urls_file" ] || {
	echo "cannot read $urls_file" >&2
	exit 1
}

# Must match slugify() in mathsisfun-algebra-render.py, or PDFs go unfound.
slugify() {
	printf '%s' "$1" |
		LC_ALL=C sed -E 's#^https?://[^/]+##; s#^/[^/]+/##; s#\.html$##; s#[^A-Za-z0-9]+#-#g; s#^-+|-+$##g'
}

declare -A slug_owner=()
files=()
missing=()
total=0
while IFS= read -r url || [ -n "$url" ]; do
	url="${url#"${url%%[![:space:]]*}"}"
	url="${url%"${url##*[![:space:]]}"}"
	[ -z "$url" ] && continue
	slug=$(slugify "$url")
	slug="${slug:-index}"
	owner="${slug_owner[$slug]-}"
	[ "$owner" = "$url" ] && continue
	total=$((total + 1))
	if [ -n "$owner" ]; then
		printf 'warning: %s has the same slug (%s) as %s, so it has no PDF of its own\n' "$url" "$slug" "$owner" >&2
		missing+=("$url")
		continue
	fi
	slug_owner[$slug]="$url"
	f="$pdf_dir/$slug.pdf"
	[ -s "$f" ] && files+=("$f") && continue
	printf 'warning: no PDF for %s (expected non-empty %s)\n' "$url" "$f" >&2
	missing+=("$url")
done <"$urls_file"

if [ "$total" -eq 0 ]; then
	echo "no URLs in $urls_file, run mathsisfun-algebra-discover.py first" >&2
	exit 1
fi
if [ "${#missing[@]}" -gt 0 ] && [ "$allow_missing" -eq 0 ]; then
	printf '%d of %d URLs have no PDF; re-render them with mathsisfun-algebra-render.py, or pass --allow-missing to merge the rest\n' \
		"${#missing[@]}" "$total" >&2
	exit 1
fi
if [ "${#files[@]}" -eq 0 ]; then
	echo "no PDFs found in $pdf_dir, run mathsisfun-algebra-render.py first" >&2
	exit 1
fi

pdfunite "${files[@]}" "$combined"

pages=$(pdfinfo "$combined" 2>/dev/null | awk '/^Pages:/ { print $2 }') || pages=""
printf 'wrote %s (%d files%s)\n' "$combined" "${#files[@]}" "${pages:+, $pages pages}"
if [ "${#missing[@]}" -gt 0 ]; then
	printf 'left out %d of %d URLs (--allow-missing), see the warnings above\n' "${#missing[@]}" "$total" >&2
fi
