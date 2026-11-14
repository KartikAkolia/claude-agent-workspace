#!/usr/bin/env python3
"""Crawl a mathsisfun.com section and list every same-section HTML page.

Stays inside whatever top-level section START is under (e.g. /algebra/,
/data/), skips worksheet generator endpoints (robots.txt disallows those
anyway), follows only same-domain links, breadth-first. Self-imposed 1s
delay between requests, failed ones included, to stay polite to the site.

Every URL is normalised to https://www.mathsisfun.com/<path>, with no query
or fragment, before it is compared or printed, so the http://, bare-domain
and ?query spellings of one page are fetched and listed once.

Only pages that fetched successfully are printed. Failed fetches go to
stderr as they happen and again in a summary at the end, and make the exit
status 1, since any page linked only from a failed one is missing too.

Usage:
    python3 mathsisfun-algebra-discover.py [start_url] > urls.txt

    # defaults to /algebra/; pass any mathsisfun.com/<section>/index.html
    # to crawl that section instead, e.g.:
    python3 mathsisfun-algebra-discover.py \\
        https://www.mathsisfun.com/data/index.html > urls.txt
"""

import sys
import time
from collections import deque
from urllib.parse import urljoin, urlparse

import requests
from bs4 import BeautifulSoup

HOSTS = ("www.mathsisfun.com", "mathsisfun.com")
DEFAULT_START = "https://www.mathsisfun.com/algebra/index.html"
HEADERS = {
    "User-Agent": "kartik-personal-study-archiver/1.0 (+offline reading, low request rate)"
}


def normalise(url: str) -> str | None:
    """Return url as https://www.mathsisfun.com/<path>, dropping any query
    and fragment, or None if it isn't an http(s) mathsisfun.com URL."""
    parts = urlparse(url)
    if parts.scheme not in ("http", "https") or parts.hostname not in HOSTS:
        return None
    return f"https://www.mathsisfun.com{parts.path or '/'}"


START = normalise(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_START)
PREFIX = "/" + urlparse(START or "").path.strip("/").split("/")[0] + "/"


def same_section(url: str) -> bool:
    # url is already normalise()d, so only the path needs checking.
    path = urlparse(url).path
    if not path.startswith(PREFIX) or not path.endswith(".html"):
        return False
    return "/worksheets/" not in path


def crawl(start: str, delay: float = 1.0) -> tuple[list[str], list[str]]:
    """Breadth-first crawl from start; returns (fetched, failed) URLs."""
    seen = {start}
    queue = deque([start])
    ordered = []
    failed = []
    while queue:
        url = queue.popleft()
        try:
            resp = requests.get(url, headers=HEADERS, timeout=15)
            resp.raise_for_status()
        except requests.RequestException as exc:
            print(f"skip {url}: {exc}", file=sys.stderr)
            failed.append(url)
            continue
        finally:
            # A 429/503 needs the pause even more than a success does.
            time.sleep(delay)
        ordered.append(url)
        soup = BeautifulSoup(resp.text, "html.parser")
        for a in soup.find_all("a", href=True):
            link = normalise(urljoin(url, a["href"]))
            if link and same_section(link) and link not in seen:
                seen.add(link)
                queue.append(link)
    return ordered, failed


def main() -> int:
    if START is None:
        print(f"not a mathsisfun.com http(s) URL: {sys.argv[1]}", file=sys.stderr)
        return 2
    ordered, failed = crawl(START)
    for url in ordered:
        print(url)
    if failed:
        print(
            f"{len(failed)} page(s) failed to fetch and are not listed"
            " (nor is anything linked only from them):",
            file=sys.stderr,
        )
        for url in failed:
            print(f"  {url}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
