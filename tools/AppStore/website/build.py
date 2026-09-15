#!/usr/bin/env python3
"""Render Spriglet's public support and privacy pages from the reviewed source text."""

import argparse
import html
from html.parser import HTMLParser
from pathlib import Path
import re
import sys

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUTPUT = HERE / "public"
ORIGIN = "https://meetspriglet.com"


def inline(text):
    # This renderer supports only the Markdown used by these two source documents.
    # Source HTML is always escaped; no scripts or remote assets are introduced.
    tokens = re.compile(r"\[([^\]]+)\]\((https://[^\s)]+|mailto:[^\s)]+)\)|\*\*(.+?)\*\*|`([^`]+)`|https://[^\s]+")
    result, end = [], 0
    for match in tokens.finditer(text):
        result.append(html.escape(text[end:match.start()]))
        label, url, bold, code = match.groups()
        if url:
            result.append(f'<a href="{html.escape(url, quote=True)}">{html.escape(label)}</a>')
        elif bold:
            result.append(f"<strong>{inline(bold)}</strong>")
        elif code:
            result.append(f"<code>{html.escape(code)}</code>")
        else:
            url = match.group().rstrip(".,;")
            suffix = match.group()[len(url):]
            result.append(f'<a href="{html.escape(url, quote=True)}">{html.escape(url)}</a>{suffix}')
        end = match.end()
    result.append(html.escape(text[end:]))
    return "".join(result)


def document(source):
    result = []
    for block in source.strip().split("\n\n"):
        if block.startswith("# "):
            continue  # The page template supplies the document's one h1.
        if block.startswith("## "):
            result.append(f"<h2>{inline(block[3:])}</h2>")
        else:
            result.append(f"<p>{inline(block)}</p>")
    return "\n".join(result)


def page(title, description, route, body):
    navigation = "".join(f'<a href="/{path}"' + (' aria-current="page"' if path == route else '')
                         + f'>{label}</a>' for path, label in (("support", "Support"), ("privacy", "Privacy")))
    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>{html.escape(title)} — Spriglet</title>
  <meta name="description" content="{html.escape(description, quote=True)}">
  <link rel="canonical" href="{ORIGIN}/{route}">
  <link rel="icon" type="image/png" href="/spriglet.png">
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  <a class="skip" href="#content">Skip to content</a>
  <header>
    <a class="brand" href="/" aria-label="Spriglet home"><img src="/spriglet.png" alt="" width="44" height="44"><span>Spriglet</span></a>
    <nav aria-label="Main navigation">{navigation}</nav>
  </header>
  <main id="content">
    <div class="eyebrow">Spriglet for Mac</div>
    <h1>{html.escape(title)}</h1>
    <article>{body}</article>
  </main>
  <footer><span>© 2026 Ali Nabipour</span><a href="mailto:support@meetspriglet.com">support@meetspriglet.com</a></footer>
</body>
</html>
'''


def outputs():
    support = (ROOT / "tools/AppStore/support-page.md").read_text()
    # Shared footer/navigation are supplied by the template.
    support = support.split("\n[Back to Spriglet]")[0]
    privacy = (ROOT / "PRIVACY.md").read_text()
    return {
        "support.html": page("How can we help?", "Help with Spriglet, your local desktop companion for Mac. Contact support and find answers to common questions.", "support", document(support)),
        "privacy.html": page("Privacy policy", "How Spriglet handles local preferences, optional diagnostics, support requests, and website visits.", "privacy", document(privacy)),
        "index.html": page("Spriglet support", "Support and privacy information for Spriglet for Mac.", "support", '<p><a href="/support">Visit Spriglet support</a> or read our <a href="/privacy">privacy policy</a>.</p>'),
        "404.html": page("Page not found", "Find support and privacy information for Spriglet.", "404", '<p>This page could not be found. <a href="/support">Visit support</a> or read the <a href="/privacy">privacy policy</a>.</p>'),
    }


class LinkCheck(HTMLParser):
    def handle_starttag(self, tag, attrs):
        values = dict(attrs)
        if tag == "script": raise ValueError("The support site must have no scripts.")
        for key in ("src", "href"):
            value = values.get(key, "")
            if value.startswith("/"):
                target = value.split("#", 1)[0].strip("/") or "index.html"
                if not Path(target).suffix: target += ".html"
                if not (OUTPUT / target).is_file(): raise ValueError(f"Missing local destination: {value}")
        if tag == "img" and "alt" not in values: raise ValueError("Image is missing alt text.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    expected = outputs()
    icon = ROOT / "Sources/Spriglet/Assets.xcassets/AppIcon.appiconset/icon_128x128@1x.png"
    try:
        OUTPUT.mkdir(parents=True, exist_ok=True)
        for name, content in expected.items():
            target = OUTPUT / name
            if args.check:
                if not target.exists() or target.read_text() != content: raise ValueError(f"Stale website page: {name}; run build.py.")
            else: target.write_text(content)
        if args.check:
            if (OUTPUT / "spriglet.png").read_bytes() != icon.read_bytes(): raise ValueError("Website icon differs from app artwork.")
        else: (OUTPUT / "spriglet.png").write_bytes(icon.read_bytes())
        for content in expected.values(): LinkCheck().feed(content)
        print("Support and privacy pages match their source; local routes and assets are valid.")
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__": sys.exit(main())
