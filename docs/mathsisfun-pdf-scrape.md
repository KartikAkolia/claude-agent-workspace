# mathsisfun.com → PDF archive

Personal offline copy of every page under a given `mathsisfun.com/<section>/`, one PDF per page plus a merged book. The scripts crawl whatever section you point them at (not just `/algebra/`) — see "Usage" below.

## Why it exists

Study material ahead of the University of Greenwich course (BSc Hons Computer Science, Year 0, starting 2026-09-14) — see `estuary/`. Not a general-purpose scraper; the crawl scope, filenames, and consent-handling are specific to this one site's structure and its ad-tech CMP.

## What ran, so far

- **`/algebra/`**, built 2026-08-30 on a different machine ("asus-vivobook"): 183/183 pages, 0 fetch/render failures. Output was `/home/kartik/Documents/Maths/pdfs/` and `algebra-mathsisfun.pdf` (1,024 pages, ~67 MB). Verified clean on start/middle/last spot-checks *for the full-page ad-consent modal only* — the small cookie-banner and its dismissal bugs (below) weren't caught at the time.
- **`/data/`** (statistics/probability), built 2026-09-02 on this machine (Windows, native, not WSL): 94/94 pages, 0 fetch/render failures. Output: `C:\Users\Kartik\Documents\Maths\data-pdfs\` (94 files) and `C:\Users\Kartik\Documents\Maths\data-mathsisfun.pdf` (458 pages, ~34 MB). Verified clean at 0/25/50/75/100% through the merged book, after fixing the two dismissal bugs below.

## Prerequisites

The scripts run fine on either Windows (native, no WSL needed) or Linux — whichever machine you're on. Verify these are present:

- **Chrome**: Playwright drives the system install directly (`channel="chrome"`), no separate Chromium download. On Windows, winget's `Google.Chrome` is typically already there; on Debian, it needs Google's apt repo added (not a default repo).
- **`python3` + pip**: `requests`, `beautifulsoup4`, `playwright`. On Windows this can go straight into the system `pip` (not externally-managed like Debian) or a throwaway venv; on Debian a venv is required:

  ```bash
  # Windows (Git Bash) — used for the /data/ run:
  python3 -m venv ~/.venvs/mathsisfun-pdf
  ~/.venvs/mathsisfun-pdf/Scripts/python.exe -m pip install requests beautifulsoup4 playwright

  # Debian — used for the /algebra/ run:
  python3 -m venv ~/.venvs/mathsisfun-pdf
  ~/.venvs/mathsisfun-pdf/bin/pip install requests beautifulsoup4 playwright
  ```

- **`poppler-utils`** (`pdfunite`, `pdfinfo`) — for merging and page-count checks. On Windows: `winget install oschwartz10612.Poppler` (installs to `%LOCALAPPDATA%\Microsoft\WinGet\Packages\oschwartz10612.Poppler_*\poppler-*\Library\bin`; a fresh shell picks up the PATH change winget makes, an already-open one needs that dir added manually). On Debian: `apt install poppler-utils`.

## Usage

```bash
cd /path/to/Github/scripts
VENV=~/.venvs/mathsisfun-pdf   # adjust bin/ vs Scripts/ for your OS

# 1. Discover every page under a section (breadth-first, same-domain, 1s delay).
#    Defaults to /algebra/; pass any other section's index page as an override.
"$VENV/bin/python" mathsisfun-algebra-discover.py > urls.txt
"$VENV/bin/python" mathsisfun-algebra-discover.py https://www.mathsisfun.com/data/index.html > urls.txt

# 2. Render each to its own PDF via a persistent Chrome profile
"$VENV/bin/python" mathsisfun-algebra-render.py urls.txt /path/to/pdfs [profile_dir]

# 3. Merge into one book, in crawl order
./mathsisfun-algebra-merge.sh urls.txt /path/to/pdfs /path/to/combined.pdf
```

The script filenames still say "algebra" (not renamed, to keep this low-churn) but all three are section-agnostic now: `discover.py` takes the start URL as an argument and derives the crawl prefix from it; `render.py` and `merge.sh` strip whichever leading path segment the URL has, not a hardcoded `/algebra/`. Use a separate `profile_dir` per section (e.g. `~/.cache/mathsisfun-data-pdf/chrome-profile`) so consent-priming for one section doesn't get mixed up with another.

Re-running step 2 is idempotent by *filename* (same URL → same slug → same destination file gets overwritten), but the script doesn't currently skip already-rendered pages — every run redoes all of them. Fine for occasional refreshes; if this becomes routine, add a skip-if-exists check.

## The gotchas (why this isn't a one-liner)

**1. The ad-tech CMP's full-page modal (the original, most severe gotcha).** The first attempt used plain `google-chrome --headless --print-to-pdf=<file> <url>` in a loop — no persistent profile. mathsisfun (or more precisely an ad-tech CMP it loads) shows a full-page "This site asks for consent to use your data" modal that darkens and covers the article. Because each `google-chrome` invocation started a brand-new, empty profile, every single page's PDF had this modal baked in.

Fix: drive one persistent browser context (Playwright + `launch_persistent_context`, pointed at a profile dir that survives across every page load in the run) and click the "Consent" button once. The consent cookie/localStorage then persists for the rest of the run, so the modal never reappears.

**2. The modal loads asynchronously — checking for it right after `networkidle` misses it (found 2026-09-02).** `render.py`'s original `dismiss_banners()` checked for the "Consent" button immediately after `page.goto(..., wait_until="networkidle")`. In practice the CMP script injects the modal ~2-3s *after* `networkidle` fires (it's not tied to network activity playwright can see), so the check always found nothing and never clicked anything — the modal was reappearing on every page in the `/data/` run despite the "priming" step supposedly having dismissed it. The `/algebra/` run's "verified clean" spot-check apparently didn't hit this, by luck of timing or because that Chrome profile already had prior real-browsing consent state baked in.

Fix: `dismiss_consent_modal()` now actively waits (`wait_for(state="visible", ...)`) rather than checking once — generously (8s) during the one-time priming step, briefly (1s) on each subsequent page since consent is genuinely sticky once granted.

**3. mathsisfun's own small "We may use Cookies" banner never actually got dismissed (found 2026-09-02).** The original code looked for `get_by_role("button", name="OK")`, but the real element is `<div id="cookOK"><div class="btn" onclick="cookOK()">OK</div></div>` — a `<div>`, not an ARIA `<button>`, so the role-based selector matched nothing and silently did nothing, on every page, in both the `/algebra/` and `/data/` runs. This banner is small and non-blocking (unlike gotcha #1), so it went unnoticed until an explicit screenshot spot-check after fixing gotcha #2.

It's also *not* sticky the way the big modal is — no cookie/localStorage gets set, so it re-renders on every single page load, meaning it has to be dismissed per-page, not just once. And clicking it doesn't remove the `#cookOK` container itself, only empties its `innerHTML` (mathsisfun's own JS quirk) — the empty, still-styled div is left behind as a small light-blue rectangle unless explicitly hidden.

Fix: `dismiss_cookie_banner()` uses a CSS locator (`#cookOK .btn`) instead of a role-based one, waits for it to appear before clicking (same async-timing issue as gotcha #2, though this one seems to render faster, ~1s), and force-hides the leftover empty `#cookOK` div via `page.evaluate()` afterward.

**Verification approach that caught #2 and #3**: don't trust "0 failures" alone — the script "succeeds" on every page regardless, because a rendered-but-wrong PDF isn't a script failure. Render actual sample pages to PNG (`pdftoppm -png -r 100 -f N -l N file.pdf`) and look at them — several points through the book, not just the first page (gotcha #3's residual banner is easy to miss on a single glance since it's a small corner artifact, and gotcha #2 was intermittent enough that a single spot-check could pass by chance).

## Politeness / robots.txt

`https://www.mathsisfun.com/robots.txt` disallows only `/worksheets/print*.php`, `/includes/`, and the 404 handler — arbitrary sections like `/algebra/` or `/data/` are unrestricted, and there's no `Crawl-delay` for a generic user-agent (only `Slurp` gets one). The discovery script still self-imposes a 1s delay between requests and sends a descriptive `User-Agent` identifying it as a low-rate personal archiver.

## Files

- `scripts/mathsisfun-algebra-discover.py` — crawler, outputs one URL per line. Takes an optional start-URL argument to crawl a different section.
- `scripts/mathsisfun-algebra-render.py` — renders each URL to a PDF (needs the venv above). Takes an optional profile-dir argument; use a distinct one per section.
- `scripts/mathsisfun-algebra-merge.sh` — `pdfunite`s the per-page PDFs into one book, in crawl order.
