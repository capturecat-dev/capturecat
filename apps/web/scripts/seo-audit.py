#!/usr/bin/env python3
"""
SEO / agent-readiness audit for every page in the sitemap.

    python3 scripts/seo-audit.py [base-url]     # default http://localhost:3200

Checks, per page: 200, no noindex (meta or header), one <title> (<= 65 chars),
one meta description (50-160 chars), unique titles and descriptions, one
canonical equal to the page's own sitemap URL, a text/markdown alternate that
resolves, one <h1>, Open Graph + Twitter card tags, JSON-LD that parses, and a
line in llms.txt. Markdown twins must send a canonical Link header pointing at
the HTML page. Exits non-zero on any error.
"""
import json
import re
import sys
import urllib.error
import urllib.request
from html.parser import HTMLParser

BASE = (sys.argv[1] if len(sys.argv) > 1 else "http://localhost:3200").rstrip("/")
UA = {"User-Agent": "Mozilla/5.0 (Macintosh) capturecat-seo-audit"}


def fetch(url, headers=None):
    req = urllib.request.Request(url, headers={**UA, **(headers or {})})
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, {k.lower(): v for k, v in r.headers.items()}, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, {k.lower(): v for k, v in e.headers.items()}, ""


class Head(HTMLParser):
    def __init__(self):
        super().__init__()
        self.titles, self.metas, self.links, self.h1 = [], [], [], 0
        self._in_title = False
        self.ld = []
        self._in_ld = False

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "title":
            self._in_title = True
            self.titles.append("")
        elif tag == "meta":
            self.metas.append(a)
        elif tag == "link":
            self.links.append(a)
        elif tag == "h1":
            self.h1 += 1
        elif tag == "script" and a.get("type") == "application/ld+json":
            self._in_ld = True
            self.ld.append("")

    def handle_endtag(self, tag):
        if tag == "title":
            self._in_title = False
        if tag == "script":
            self._in_ld = False

    def handle_data(self, data):
        if self._in_title:
            self.titles[-1] += data
        if self._in_ld:
            self.ld[-1] += data

    def meta(self, key):
        return [m.get("content", "") for m in self.metas if m.get("name") == key or m.get("property") == key]


status, _, sitemap = fetch(BASE + "/sitemap.xml")
locs = re.findall(r"<loc>([^<]+)</loc>", sitemap)
site_origin = re.match(r"https?://[^/]+", locs[0]).group(0)
_, _, llms = fetch(BASE + "/llms.txt")

errors, warnings = [], []
seen_titles, seen_descs = {}, {}

for loc in locs:
    path = loc[len(site_origin):] or "/"
    code, headers, html = fetch(BASE + path)
    tag = path
    if code != 200:
        errors.append(f"{tag}: HTTP {code}")
        continue
    if "noindex" in headers.get("x-robots-tag", "").lower():
        errors.append(f"{tag}: X-Robots-Tag noindex")
    h = Head()
    h.feed(html)

    if any("noindex" in c for c in h.meta("robots")):
        errors.append(f"{tag}: meta robots noindex")
    if len(h.titles) != 1:
        errors.append(f"{tag}: {len(h.titles)} <title> tags")
    title = h.titles[-1].strip() if h.titles else ""
    if len(title) > 65:
        warnings.append(f"{tag}: title {len(title)} chars: {title}")
    seen_titles.setdefault(title, []).append(tag)

    descs = h.meta("description")
    if len(descs) != 1:
        errors.append(f"{tag}: {len(descs)} meta descriptions")
    desc = descs[-1] if descs else ""
    if not 50 <= len(desc) <= 160:
        warnings.append(f"{tag}: description {len(desc)} chars")
    seen_descs.setdefault(desc, []).append(tag)

    canon = [l.get("href") for l in h.links if l.get("rel") == "canonical"]
    if len(canon) != 1:
        errors.append(f"{tag}: {len(canon)} canonical links")
    elif canon[0] != loc:
        errors.append(f"{tag}: canonical {canon[0]} != sitemap {loc}")

    alts = [l for l in h.links if l.get("rel") == "alternate" and l.get("type") == "text/markdown"]
    if len(alts) != 1:
        errors.append(f"{tag}: {len(alts)} markdown alternates")
    else:
        md_code, md_headers, _ = fetch(BASE + alts[0]["href"] if alts[0]["href"].startswith("/") else alts[0]["href"])
        if md_code != 200:
            errors.append(f"{tag}: markdown alternate {alts[0]['href']} -> {md_code}")
        link_hdr = md_headers.get("link", "")
        if f'<{loc}>; rel="canonical"' not in link_hdr:
            errors.append(f"{tag}: markdown twin lacks canonical Link header (got {link_hdr!r})")

    if h.h1 != 1:
        errors.append(f"{tag}: {h.h1} <h1> elements")

    for key in ("og:title", "og:description", "og:url", "og:type", "og:image", "twitter:card"):
        if not h.meta(key):
            errors.append(f"{tag}: missing {key}")
    og_url = h.meta("og:url")
    if og_url and og_url[0] != loc:
        errors.append(f"{tag}: og:url {og_url[0]} != {loc}")

    for block in h.ld:
        try:
            json.loads(block)
        except ValueError as e:
            errors.append(f"{tag}: JSON-LD does not parse ({e})")

    md_url = "/index.md" if path == "/" else f"{path}.md"
    if f"{md_url})" not in llms:
        errors.append(f"{tag}: not listed in llms.txt")

for title, pages in seen_titles.items():
    if len(pages) > 1:
        errors.append(f"duplicate title on {pages}: {title}")
for desc, pages in seen_descs.items():
    if len(pages) > 1:
        errors.append(f"duplicate description on {pages}")

print(f"{len(locs)} pages audited against {BASE}")
for w in warnings:
    print("WARN ", w)
for e in errors:
    print("ERROR", e)
print(f"{len(errors)} errors, {len(warnings)} warnings")
sys.exit(1 if errors else 0)
