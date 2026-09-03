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
    path = re.sub(
        r"^/[^/]+/", "", path
    )  # drop leading section, e.g. /algebra/ or /data/
    path = re.sub(r"\.html$", "", path)
    slug = re.sub(r"[^A-Za-z0-9]+", "-", path).strip("-")
    return slug or "index"


def dismiss_consent_modal(page, timeout: int) -> None:
    # The ad-tech CMP's full-page "This site asks for consent to use your
    # data" modal. It's injected by an async ad script well after
    # networkidle (~2-3s observed), so this has to actively wait for it
    # rather than checking immediately — an immediate check just sees an
    # empty page and assumes there's nothing to dismiss. Once accepted,
    # though, it's genuinely sticky and won't reappear for the rest of the
    # persistent-profile session.
    try:
        btn = page.get_by_role("button", name="Consent", exact=True)
        btn.first.wait_for(state="visible", timeout=timeout)
        btn.first.click(timeout=1500)
        btn.first.wait_for(state="hidden", timeout=1500)
    except Exception:  # noqa: S110, BLE001 — best-effort dismiss; the modal
        pass  # not showing up is the expected/common case, not an error


def dismiss_cookie_banner(page, timeout: int) -> None:
    # mathsisfun's own small "We may use Cookies" notice is a
    # <div class="btn" onclick="cookOK()">OK</div>, not a <button>, so it
    # needs a CSS locator rather than role-based matching. Unlike the modal
    # above, dismissing it isn't sticky across navigations (no cookie/local
    # storage set — it just re-renders on every page load, on its own timer
    # that isn't tied to networkidle either), so this has to run before
    # every page.pdf() call, and also has to wait for the element to
    # actually appear rather than checking it immediately.
    try:
        ok = page.locator("#cookOK .btn")
        ok.first.wait_for(state="visible", timeout=timeout)
        ok.first.click(timeout=1500)
        ok.first.wait_for(state="hidden", timeout=1500)
    except Exception:  # noqa: S110, BLE001 — best-effort dismiss, see above
        pass
    # cookOK()'s own JS just empties #cookOK's innerHTML on click, it
    # doesn't hide the div — so an empty, still-styled (light-blue
    # background) box is left behind in the corner. Force it closed too.
    try:
        page.evaluate(
            "document.querySelectorAll('#cookOK').forEach(el => { if (!el.textContent.trim()) el.style.display = 'none'; })"
        )
    except Exception:  # noqa: S110, BLE001 — same rationale
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

        # Prime consent once up front. Generous timeout here since it's a
        # one-time cost and the modal can take a couple seconds to load.
        page.goto(urls[0], wait_until="networkidle")
        dismiss_consent_modal(page, timeout=8000)
        dismiss_cookie_banner(page, timeout=3000)

        for i, url in enumerate(urls, 1):
            dest = out_dir / f"{slugify(url)}.pdf"
            try:
                page.goto(url, wait_until="networkidle", timeout=30000)
                # Short timeout per page: consent is sticky (shouldn't
                # reappear) and the cookie banner, when it shows at all,
                # tends to render within ~1s.
                dismiss_consent_modal(page, timeout=1000)
                dismiss_cookie_banner(page, timeout=2500)
                page.pdf(
                    path=str(dest),
                    format="A4",
                    print_background=True,
                    margin={
                        "top": "12mm",
                        "bottom": "12mm",
                        "left": "10mm",
                        "right": "10mm",
                    },
                )
                print(f"[{i}/{len(urls)}] ok: {url}", flush=True)
            except Exception as exc:  # noqa: BLE001 — one bad page shouldn't kill the whole run
                print(
                    f"[{i}/{len(urls)}] FAILED: {url}: {exc}",
                    file=sys.stderr,
                    flush=True,
                )
                fail += 1

        ctx.close()

    print(f"done, {fail} failure(s)")
    return 1 if fail else 0


if __name__ == "__main__":
    raise SystemExit(main())
