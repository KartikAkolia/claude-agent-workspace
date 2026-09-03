#!/usr/bin/env bash
# Combine all per-page PDFs into one book, in urls.txt crawl order.
set -euo pipefail

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
	# drops leading section (/algebra/, /data/, ...), same rule as render.py
	printf '%s' "$1" |
		sed -E 's#^https?://[^/]+##; s#^/[^/]+/##; s#\.html$##; s#[^A-Za-z0-9]+#-#g; s#^-+|-+$##g'
}

files=()
while IFS= read -r url; do
	url="${url%$'\r'}" # urls.txt may have CRLF line endings (e.g. from Python on Windows)
	[ -z "$url" ] && continue
	slug=$(slugify "$url")
	f="$pdf_dir/${slug:-index}.pdf"
	[ -s "$f" ] && files+=("$f")
done <"$urls_file"

if [ "${#files[@]}" -eq 0 ]; then
	echo "no PDFs found in $pdf_dir, run mathsisfun-algebra-render.py first" >&2
	exit 1
fi

pdfunite "${files[@]}" "$combined"
echo "wrote $combined (${#files[@]} pages)"
