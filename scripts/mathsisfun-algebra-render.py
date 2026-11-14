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

A page counts as failed if navigation errors or times out, or if the server
answers with a non-2xx status other than 304 Not Modified, which is the
profile's cache revalidating a page it holds (page.goto doesn't raise on
404/500, so that's checked explicitly). A URL whose slug another URL already took this run is
also failed rather than overwriting that PDF; a repeated identical URL is
just skipped. Failures are listed at the end and make the exit status 1.
"""

import re
import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

DEFAULT_PROFILE = Path.home() / ".cache" / "mathsisfun-algebra-pdf" / "chrome-profile"


def slugify(url: str) -> str:
    # mathsisfun-algebra-merge.sh's slugify() must stay identical to this, or
    # the merge looks for PDFs under names this script never wrote. The rule
    # is lossy (a/b.html and a-b.html both become a-b), so main() refuses a
    # second URL that lands on a slug already used this run.
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


def render_page(page, url: str, dest: Path) -> str | None:
    """Load url and print it to dest. Returns why it failed, or None."""
    try:
        resp = page.goto(url, wait_until="networkidle", timeout=30000)
        if resp is None:
            return "no response"
        # 304 is the persistent profile's cache revalidating a page it already
        # holds: the page rendered is the cached 200 body, so it's a success
        # even though Response.ok only covers 200-299.
        if not resp.ok and resp.status != 304:
            return f"HTTP {resp.status}"
        # Short timeout per page: consent is sticky (shouldn't reappear) and
        # the cookie banner, when it shows at all, tends to render within ~1s.
        dismiss_consent_modal(page, timeout=1000)
        dismiss_cookie_banner(page, timeout=2500)
        page.pdf(
            path=str(dest),
            format="A4",
            print_background=True,
            margin={"top": "12mm", "bottom": "12mm", "left": "10mm", "right": "10mm"},
        )
    except Exception as exc:  # noqa: BLE001 — one bad page shouldn't kill the whole run
        return str(exc)
    return None


def main() -> int:
    urls_file = Path(sys.argv[1] if len(sys.argv) > 1 else "urls.txt")
    out_dir = Path(sys.argv[2] if len(sys.argv) > 2 else "pdfs")
    profile = Path(sys.argv[3]) if len(sys.argv) > 3 else DEFAULT_PROFILE
    try:
        lines = urls_file.read_text().splitlines()
    except OSError as exc:
        print(f"cannot read {urls_file}: {exc}", file=sys.stderr)
        return 1
    urls = [u.strip() for u in lines if u.strip()]
    if not urls:
        print(f"no URLs in {urls_file}, nothing to render", file=sys.stderr)
        return 1
    out_dir.mkdir(parents=True, exist_ok=True)
    profile.mkdir(parents=True, exist_ok=True)

    ok = 0
    failed: list[tuple[str, str]] = []
    slug_owner: dict[str, str] = {}  # slug -> first URL that claimed it
    with sync_playwright() as p:
        ctx = p.chromium.launch_persistent_context(
            str(profile), channel="chrome", headless=True
        )
        page = ctx.new_page()

        # Prime consent once up front. Generous timeout here since it's a
        # one-time cost and the modal can take a couple seconds to load.
        # Not fatal: if this page won't load, the loop below still tries to
        # dismiss the modal on every page, just with a shorter wait.
        try:
            page.goto(urls[0], wait_until="networkidle", timeout=30000)
            dismiss_consent_modal(page, timeout=8000)
            dismiss_cookie_banner(page, timeout=3000)
        except Exception as exc:  # noqa: BLE001 — priming is best-effort
            print(
                f"consent priming on {urls[0]} failed ({exc}), continuing",
                file=sys.stderr,
                flush=True,
            )

        for i, url in enumerate(urls, 1):
            tag = f"[{i}/{len(urls)}]"
            slug = slugify(url)
            owner = slug_owner.get(slug)
            if owner == url:
                print(f"{tag} skip, listed twice: {url}", flush=True)
                continue
            if owner is None:
                # Claimed even if the render below fails, so the merge (which
                # also takes the first URL per slug) never pairs this
                # position in the book with another URL's PDF.
                slug_owner[slug] = url
                reason = render_page(page, url, out_dir / f"{slug}.pdf")
            else:
                reason = (
                    f"slug {slug!r} already used by {owner}, not overwriting its PDF"
                )
            if reason is None:
                ok += 1
                print(f"{tag} ok: {url}", flush=True)
            else:
                print(f"{tag} FAILED: {url}: {reason}", file=sys.stderr, flush=True)
                failed.append((url, reason))

        ctx.close()

    print(f"done, {ok} ok, {len(failed)} failure(s)", flush=True)
    if failed:
        print("failed pages (not rendered this run):", file=sys.stderr)
        for url, reason in failed:
            print(f"  {url}: {reason}", file=sys.stderr)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
