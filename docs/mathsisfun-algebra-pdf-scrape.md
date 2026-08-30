# mathsisfun.com/algebra/ → PDF archive

Personal offline copy of every page under `mathsisfun.com/algebra/`, one PDF per page plus a merged book. Built 2026-08-30, working: 183/183 pages, verified clean (no ad-consent overlay) on start/middle/end pages of the merged output.

## Why it exists

Study material ahead of the University of Greenwich course (BSc Hons Computer Science, Year 0, starting 2026-09-14) — see `estuary/`. Not a general-purpose scraper; the crawl scope, filenames, and consent-handling are specific to this one site's structure and its ad-tech CMP.

## What ran, last time

- Output: `/home/kartik/Documents/Maths/pdfs/` (183 individual files) and `/home/kartik/Documents/Maths/algebra-mathsisfun.pdf` (merged, 1,024 pages, ~67 MB).
- 183 pages discovered under `/algebra/`, 0 fetch failures, 0 render failures.

## Prerequisites

Already present on this machine (asus-vivobook), verified 2026-08-30:

- `google-chrome` — Playwright drives this directly (`channel="chrome"`), no separate Chromium download.
- `python3` with `requests` + `bs4` (for discovery) — system packages, already installed.
- `poppler-utils` (`pdfunite`, `pdfinfo`) — for merging and page-count checks.
- A throwaway venv for `playwright` (Debian's `python3` is externally-managed, so `pip install` needs a venv):

  ```bash
  python3 -m venv ~/.venvs/mathsisfun-pdf
  ~/.venvs/mathsisfun-pdf/bin/pip install playwright
  ```

  No `playwright install` step needed — the render script launches the system Chrome via `channel="chrome"`, not Playwright's bundled Chromium.

## Usage

```bash
cd /home/kartik/claude-agent-workspace/scripts
VENV=~/.venvs/mathsisfun-pdf

# 1. Discover every page under /algebra/ (breadth-first, same-domain, 1s delay)
python3 mathsisfun-algebra-discover.py > urls.txt

# 2. Render each to its own PDF via a persistent Chrome profile
"$VENV/bin/python" mathsisfun-algebra-render.py urls.txt /home/kartik/Documents/Maths/pdfs

# 3. Merge into one book, in crawl order
./mathsisfun-algebra-merge.sh urls.txt /home/kartik/Documents/Maths/pdfs /home/kartik/Documents/Maths/algebra-mathsisfun.pdf
```

Re-running step 2 is idempotent by *filename* (same URL → same slug → same destination file gets overwritten), but the script doesn't currently skip already-rendered pages the way the old bash version did — every run redoes all 183. Fine for occasional refreshes; if this becomes routine, add a skip-if-exists check to `mathsisfun-algebra-render.py`.

## The gotcha (why this isn't a one-liner)

The first attempt used plain `google-chrome --headless --print-to-pdf=<file> <url>` in a loop — no persistent profile. mathsisfun (or more precisely an ad-tech CMP it loads, not mathsisfun's own small "We may use Cookies" banner) shows a full-page "This site asks for consent to use your data" modal that darkens and covers the article. Because each `google-chrome` invocation started a brand-new, empty profile, **every single page's PDF had this modal baked in** — confirmed by spot-checking start/middle/end pages of the first merged output.

Fix: drive one persistent browser context (Playwright + `launch_persistent_context`, pointed at a profile dir that survives across all 183 page loads) and click the "Consent" button once at the start. The consent cookie/localStorage then persists for the rest of the run, so the modal never reappears. `mathsisfun-algebra-render.py` also re-checks for the "Consent" or small "OK" banner on every page (`dismiss_banners()`) as a defensive no-op in case a page shows it again.

Verification approach that caught this: don't trust "0 failures" alone — the script "succeeded" on every page both times, because a rendered-but-wrong PDF isn't a script failure. Render actual sample pages to PNG (`pdftoppm -png -r 100 -f N -l N file.pdf`) and look at them. Checked first, one from the middle, and last page of the merged PDF each time.

## Politeness / robots.txt

`https://www.mathsisfun.com/robots.txt` disallows only `/worksheets/print*.php`, `/includes/`, and the 404 handler — `/algebra/` itself is unrestricted, and there's no `Crawl-delay` for a generic user-agent (only `Slurp` gets one). The discovery script still self-imposes a 1s delay between requests and sends a descriptive `User-Agent` identifying it as a low-rate personal archiver.

## Files

- `scripts/mathsisfun-algebra-discover.py` — crawler, outputs one URL per line
- `scripts/mathsisfun-algebra-render.py` — renders each URL to a PDF (needs the venv above)
- `scripts/mathsisfun-algebra-merge.sh` — `pdfunite`s the per-page PDFs into one book, in crawl order
