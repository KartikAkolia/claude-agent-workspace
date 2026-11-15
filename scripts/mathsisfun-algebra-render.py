#!/usr/bin/env python3
"""Render every URL in urls.txt to a PDF through one persistent Chrome profile, so
the ad-consent modal is dismissed once. Needs playwright and google-chrome.

Usage: .venv/bin/python mathsisfun-algebra-render.py urls.txt out_dir [profile_dir]
"""

import contextlib
import re
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

DEFAULT_PROFILE = Path.home() / ".cache" / "mathsisfun-algebra-pdf" / "chrome-profile"
MARGIN = {"top": "12mm", "bottom": "12mm", "left": "10mm", "right": "10mm"}


def slugify(url: str) -> str:
    # Must match slugify() in mathsisfun-algebra-merge.sh, or the merge misses PDFs.
    path = re.sub(r"^https?://[^/]+", "", url)
    path = re.sub(r"^/[^/]+/", "", path)
    path = re.sub(r"\.html$", "", path)
    slug = re.sub(r"[^A-Za-z0-9]+", "-", path).strip("-")
    return slug or "index"


def dismiss(button, timeout: int) -> None:
    with contextlib.suppress(Exception):
        button.wait_for(state="visible", timeout=timeout)
        button.click(timeout=1500)
        button.wait_for(state="hidden", timeout=1500)


def dismiss_consent_modal(page, timeout: int) -> None:
    dismiss(page.get_by_role("button", name="Consent", exact=True).first, timeout)


def dismiss_cookie_banner(page, timeout: int) -> None:
    dismiss(page.locator("#cookOK .btn").first, timeout)
    with contextlib.suppress(Exception):
        page.evaluate(
            "document.querySelectorAll('#cookOK').forEach(el => { if (!el.textContent.trim()) el.style.display = 'none'; })"
        )


def render_page(page, url: str, dest: Path) -> str | None:
    try:
        resp = page.goto(url, wait_until="networkidle", timeout=30000)
        if resp is None:
            return "no response"
        if not resp.ok and resp.status != 304:
            return f"HTTP {resp.status}"
        dismiss_consent_modal(page, timeout=1000)
        dismiss_cookie_banner(page, timeout=2500)
        page.pdf(path=str(dest), format="A4", print_background=True, margin=MARGIN)
    except Exception as exc:  # noqa: BLE001
        return str(exc)
    return None


def render_all(page, urls: list[str], out_dir: Path) -> tuple[int, list]:
    try:
        page.goto(urls[0], wait_until="networkidle", timeout=30000)
        dismiss_consent_modal(page, timeout=8000)
        dismiss_cookie_banner(page, timeout=3000)
    except Exception as exc:  # noqa: BLE001
        print(
            f"consent priming on {urls[0]} failed ({exc}), continuing",
            file=sys.stderr,
            flush=True,
        )
    ok, failed, slug_owner = 0, [], {}
    for i, url in enumerate(urls, 1):
        tag, slug = f"[{i}/{len(urls)}]", slugify(url)
        owner = slug_owner.get(slug)
        if owner == url:
            print(f"{tag} skip, listed twice: {url}", flush=True)
            continue
        if owner is None:
            slug_owner[slug] = url
            reason = render_page(page, url, out_dir / f"{slug}.pdf")
        else:
            reason = f"slug {slug!r} already used by {owner}, not overwriting its PDF"
        if reason is None:
            ok += 1
            print(f"{tag} ok: {url}", flush=True)
        else:
            print(f"{tag} FAILED: {url}: {reason}", file=sys.stderr, flush=True)
            failed.append((url, reason))
    return ok, failed


def main() -> int:
    urls_file = Path(sys.argv[1] if len(sys.argv) > 1 else "urls.txt")
    out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else "pdfs")
    profile = Path(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_PROFILE
    try:
        urls = [u.strip() for u in urls_file.read_text().splitlines() if u.strip()]
    except OSError as exc:
        print(f"cannot read {urls_file}: {exc}", file=sys.stderr)
        return 1
    if not urls:
        print(f"no URLs in {urls_file}, nothing to render", file=sys.stderr)
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)
    profile.mkdir(parents=True, exist_ok=True)
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(profile), channel="chrome", headless=True
        )
        ok, failed = render_all(ctx.new_page(), urls, out_dir)
        ctx.close()
    print(f"done, {ok} ok, {len(failed)} failure(s)", flush=True)
    if failed:
        print("failed pages (not rendered this run):", file=sys.stderr)
    for url, reason in failed:
        print(f"  {url}: {reason}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
