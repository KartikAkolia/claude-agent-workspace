#!/usr/bin/env bash
# Combine all per-page PDFs into one book, in urls.txt crawl order.
#
# Every URL in urls.txt needs a non-empty PDF in pdf_dir. If any are missing,
# this lists them and stops without writing the book, unless --allow-missing
# is given, in which case it merges the rest and still lists what it left out.
# A URL whose slug an earlier URL already took counts as missing, since
# render.py refuses to render it over that PDF; the same URL listed twice is
# merged once.
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

slugify() {
	# Must stay identical to slugify() in mathsisfun-algebra-render.py: drops
	# the leading section (/algebra/, /data/, ...) and .html, then turns every
	# run of non-alphanumerics into one dash. LC_ALL=C keeps A-Z/a-z ASCII-only,
	# matching Python's re.
	printf '%s' "$1" |
		LC_ALL=C sed -E 's#^https?://[^/]+##; s#^/[^/]+/##; s#\.html$##; s#[^A-Za-z0-9]+#-#g; s#^-+|-+$##g'
}

declare -A slug_owner=() # slug -> first URL that claimed it, as in render.py
files=()
missing=()
total=0
while IFS= read -r url || [ -n "$url" ]; do
	# Trim surrounding whitespace (CR included, for CRLF files) the same way
	# render.py's str.strip() does, so both derive the same slug.
	url="${url#"${url%%[![:space:]]*}"}"
	url="${url%"${url##*[![:space:]]}"}"
	[ -z "$url" ] && continue
	slug=$(slugify "$url")
	slug="${slug:-index}"
	owner="${slug_owner[$slug]-}"
	[ "$owner" = "$url" ] && continue # listed twice: merge it once
	total=$((total + 1))
	if [ -n "$owner" ]; then
		printf 'warning: %s has the same slug (%s) as %s, so it has no PDF of its own\n' "$url" "$slug" "$owner" >&2
		missing+=("$url")
		continue
	fi
	slug_owner[$slug]="$url"
	f="$pdf_dir/$slug.pdf"
	if [ -s "$f" ]; then
		files+=("$f")
	else
		printf 'warning: no PDF for %s (expected non-empty %s)\n' "$url" "$f" >&2
		missing+=("$url")
	fi
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

pages=""
if command -v pdfinfo >/dev/null 2>&1; then
	pages=$(pdfinfo "$combined" 2>/dev/null | awk '/^Pages:/ { print $2 }') || pages=""
fi
if [ -n "$pages" ]; then
	printf 'wrote %s (%d files, %s pages)\n' "$combined" "${#files[@]}" "$pages"
else
	printf 'wrote %s (%d files)\n' "$combined" "${#files[@]}"
fi
if [ "${#missing[@]}" -gt 0 ]; then
	printf 'left out %d of %d URLs (--allow-missing), see the warnings above\n' "${#missing[@]}" "$total" >&2
fi
