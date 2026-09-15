#!/usr/bin/env python3
"""Verify the served support site, including content, redirects, and error handling."""

import argparse
from pathlib import Path
import sys
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

PUBLIC = Path(__file__).resolve().parent / "public"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("origin", help="For example, https://meetspriglet.com")
    origin = parser.parse_args().origin.rstrip("/")
    parts = urlsplit(origin)
    if parts.scheme not in {"http", "https"} or not parts.netloc or parts.path or parts.query or parts.fragment or parts.username:
        parser.error("Supply an HTTP(S) origin without a path or credentials.")
    opener = build_opener(NoRedirect())

    def fetch(path):
        try:
            return opener.open(Request(origin + path, headers={"User-Agent": "SprigletWebsiteCheck/1.0"}), timeout=30)
        except HTTPError as response:
            return response

    try:
        for route, filename in (("/support", "support.html"), ("/privacy", "privacy.html"),
                                ("/style.css", "style.css"), ("/spriglet.png", "spriglet.png")):
            with fetch(route) as response:
                if response.status != 200:
                    raise ValueError(f"{route}: expected 200, received {response.status}")
                if response.read() != (PUBLIC / filename).read_bytes():
                    raise ValueError(f"{route}: served content differs from the prepared files")
                if response.headers.get("X-Content-Type-Options") != "nosniff":
                    raise ValueError(f"{route}: missing security headers")
                if "default-src 'none'" not in response.headers.get("Content-Security-Policy", ""):
                    raise ValueError(f"{route}: missing expected content security policy")
            print(f"PASS {route}: exact prepared content and security headers")
        with fetch("/") as response:
            if response.status != 302 or response.headers.get("Location") not in {"/support", origin + "/support"}:
                raise ValueError("Root must temporarily redirect to /support")
        print("PASS /: temporary redirect to support")
        with fetch("/missing-spriglet-page") as response:
            if response.status != 404 or response.read() != (PUBLIC / "404.html").read_bytes():
                raise ValueError("Unknown routes must serve the prepared 404 page with status 404")
        print("PASS unknown route: helpful 404 page")
    except (OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
