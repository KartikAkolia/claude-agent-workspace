#!/usr/bin/env python3
"""Crawl a mathsisfun.com section and list every same-section HTML page.

Stays inside whatever top-level section START is under (e.g. /algebra/,
/data/), skips worksheet generator endpoints (robots.txt disallows those
anyway), follows only same-domain links, breadth-first. Self-imposed 1s
delay between requests to stay polite to the site.

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

START = (sys.argv[1].split("#")[0] if len(sys.argv) > 1
         else "https://www.mathsisfun.com/algebra/index.html")
PREFIX = "/" + urlparse(START).path.strip("/").split("/")[0] + "/"
HEADERS = {
    "User-Agent": "kartik-personal-study-archiver/1.0 (+offline reading, low request rate)"
}


def same_section(url: str) -> bool:
    parts = urlparse(url)
    if parts.netloc not in ("www.mathsisfun.com", "mathsisfun.com"):
        return False
    if not parts.path.startswith(PREFIX):
        return False
    if not parts.path.endswith(".html"):
        return False
    if "/worksheets/" in parts.path:
        return False
    return True


def crawl(start: str, delay: float = 1.0) -> list[str]:
    seen = {start}
    queue = deque([start])
    ordered = []
    while queue:
        url = queue.popleft()
        ordered.append(url)
        try:
            resp = requests.get(url, headers=HEADERS, timeout=15)
            resp.raise_for_status()
        except requests.RequestException as exc:
            print(f"skip {url}: {exc}", file=sys.stderr)
            continue
        soup = BeautifulSoup(resp.text, "html.parser")
        for a in soup.find_all("a", href=True):
            link = urljoin(url, a["href"].split("#")[0])
            if same_section(link) and link not in seen:
                seen.add(link)
                queue.append(link)
        time.sleep(delay)
    return ordered


if __name__ == "__main__":
    for url in crawl(START):
        print(url)
