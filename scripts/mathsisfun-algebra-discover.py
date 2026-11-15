#!/usr/bin/env python3
# Docs: docs/mathsisfun-pdf-scrape.md
"""Crawl one mathsisfun.com section breadth-first and print each page that fetched.

Usage: python3 mathsisfun-algebra-discover.py [start_url] > urls.txt
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
    parts = urlparse(url)
    if parts.scheme not in ("http", "https") or parts.hostname not in HOSTS:
        return None
    return f"https://www.mathsisfun.com{parts.path or '/'}"


START = normalise(sys.argv[1] if len(sys.argv) > 1 else DEFAULT_START)
PREFIX = "/" + urlparse(START or "").path.strip("/").split("/")[0] + "/"


def same_section(url: str) -> bool:
    path = urlparse(url).path
    if not path.startswith(PREFIX) or not path.endswith(".html"):
        return False
    return "/worksheets/" not in path


def crawl(start: str, delay: float = 1.0) -> tuple[list[str], list[str]]:
    seen, queue = {start}, deque([start])
    ordered, failed = [], []
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
            time.sleep(delay)
        ordered.append(url)
        anchors = BeautifulSoup(resp.text, "html.parser").find_all("a", href=True)
        links = dict.fromkeys(normalise(urljoin(url, a["href"])) for a in anchors)
        new = [u for u in links if u and same_section(u) and u not in seen]
        seen.update(new)
        queue.extend(new)
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
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
