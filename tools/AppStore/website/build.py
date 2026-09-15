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


def page(context, title, description, route, body):
    name = html.escape(context["appName"])
    origin = html.escape(context["websiteURL"], quote=True)
    email = html.escape(context["supportEmail"], quote=True)
    copyright = html.escape(context["copyright"])
    navigation = "".join(f'<a href="/{path}"' + (' aria-current="page"' if path == route else '')
                         + f'>{label}</a>' for path, label in (("support", "Support"), ("privacy", "Privacy")))
    return f'''<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="color-scheme" content="light dark">
  <title>{html.escape(title)} — {name}</title>
  <meta name="description" content="{html.escape(description, quote=True)}">
  <link rel="canonical" href="{origin}/{route}">
  <link rel="icon" type="image/png" href="/spriglet.png">
  <link rel="stylesheet" href="/style.css">
</head>
<body>
  <a class="skip" href="#content">Skip to content</a>
  <header>
    <a class="brand" href="/" aria-label="{name} home"><img src="/spriglet.png" alt="" width="44" height="44"><span>{name}</span></a>
    <nav aria-label="Main navigation">{navigation}</nav>
  </header>
  <main id="content">
    <div class="eyebrow">{name} for Mac</div>
    <h1>{html.escape(title)}</h1>
    <article>{body}</article>
  </main>
  <footer><span>© {copyright}</span><a href="mailto:{email}">{email}</a></footer>
</body>
</html>
'''


def outputs(context, documents):
    support = documents["support"].split("\n[Back to ")[0]
    name = context["appName"]
    return {
        "support.html": page(context, context["supportTitle"], f"Help with {name}, your local desktop companion for Mac. Contact support and find answers to common questions.", "support", document(support)),
        "privacy.html": page(context, context["privacyTitle"], f"How {name} handles local preferences, optional diagnostics, support requests, and website visits.", "privacy", document(documents["privacy"])),
        "index.html": page(context, f"{name} support", f"Support and privacy information for {name} for Mac.", "support", '<p><a href="/support">Visit support</a> or read our <a href="/privacy">privacy policy</a>.</p>'),
        "404.html": page(context, "Page not found", f"Find support and privacy information for {name}.", "404", '<p>This page could not be found. <a href="/support">Visit support</a> or read the <a href="/privacy">privacy policy</a>.</p>'),
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
    import subprocess
    subprocess.run([sys.executable, str(ROOT / "tools/SharedContent/sync.py"), *(["--check"] if args.check else [])], check=True)
    try:
        for path in OUTPUT.glob("*.html"): LinkCheck().feed(path.read_text())
        print("Shared content, website routes, and assets are valid.")
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__": sys.exit(main())
