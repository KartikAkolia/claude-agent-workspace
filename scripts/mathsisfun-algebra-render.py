#!/usr/bin/env python3
"""Render every URL in urls.txt to a clean PDF via a persistent Chrome
profile, so mathsisfun's ad-consent modal gets dismissed once and never
reappears (a fresh profile per page, e.g. plain `chrome --print-to-pdf`,
re-triggers the dialog on every single page and bakes it into the PDF).

Requires: a venv with `playwright` installed, e.g.
    python3 -m venv .venv && .venv/bin/pip install playwright
Uses the system `google-chrome` (channel="chrome") — no separate Chromium
download needed.

Usage:
    .venv/bin/python mathsisfun-algebra-render.py urls.txt out_dir [profile_dir]
"""
import re
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

DEFAULT_PROFILE = Path.home() / ".cache" / "mathsisfun-algebra-pdf" / "chrome-profile"


def slugify(url: str) -> str:
    path = re.sub(r"^https?://[^/]+", "", url)
    path = re.sub(r"^/algebra/", "", path)
    path = re.sub(r"\.html$", "", path)
    slug = re.sub(r"[^A-Za-z0-9]+", "-", path).strip("-")
    return slug or "index"


def dismiss_banners(page) -> None:
    for role, name in [("button", "Consent"), ("button", "OK")]:
        try:
            btn = page.get_by_role(role, name=name, exact=True)
            if btn.count() and btn.first.is_visible():
                btn.first.click(timeout=1500)
        except Exception:
            pass


def main() -> int:
    urls_file = Path(sys.argv[1] if len(sys.argv) > 1 else "urls.txt")
    out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else "pdfs")
    profile = Path(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_PROFILE
    out_dir.mkdir(parents=True, exist_ok=True)
    profile.mkdir(parents=True, exist_ok=True)
    urls = [u.strip() for u in urls_file.read_text().splitlines() if u.strip()]

    fail = 0
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(profile), channel="chrome", headless=True
        )
        page = ctx.new_page()

        # Prime consent once up front.
        page.goto(urls[0], wait_until="networkidle")
        dismiss_banners(page)

        for i, url in enumerate(urls, 1):
            dest = out_dir / f"{slugify(url)}.pdf"
            try:
                page.goto(url, wait_until="networkidle", timeout=30000)
                dismiss_banners(page)
                page.pdf(path=str(dest), format="A4", print_background=True,
                         margin={"top": "12mm", "bottom": "12mm",
                                 "left": "10mm", "right": "10mm"})
                print(f"[{i}/{len(urls)}] ok: {url}", flush=True)
            except Exception as exc:
                print(f"[{i}/{len(urls)}] FAILED: {url}: {exc}", file=sys.stderr, flush=True)
                fail += 1

        ctx.close()

    print(f"done, {fail} failure(s)")
    return 1 if fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
