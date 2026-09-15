#!/usr/bin/env python3
"""Check production availability without assuming main has already been deployed."""

import json
from pathlib import Path
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[2]


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def main():
    origin = json.loads((ROOT / 'Configuration/Shared/brand.json').read_text())['websiteURL'].rstrip('/')
    opener = build_opener(NoRedirect())
    for route, expected in (('/support', 200), ('/privacy', 200), ('/style.css', 200), ('/spriglet.png', 200), ('/', 302), ('/missing-spriglet-page', 404)):
        try:
            response = opener.open(Request(origin + route, headers={'User-Agent': 'SprigletAvailability/1.0'}), timeout=30)
        except HTTPError as error:
            response = error
        with response:
            if response.status != expected:
                raise ValueError(f'{route}: expected {expected}, received {response.status}')
            if expected == 200 and (response.headers.get('X-Content-Type-Options') != 'nosniff' or "default-src 'none'" not in response.headers.get('Content-Security-Policy', '')):
                raise ValueError(f'{route}: required security headers missing')
            if route == '/' and response.headers.get('Location') not in ('/support', origin + '/support'):
                raise ValueError('Root redirect changed unexpectedly')
            if route in ('/support', '/privacy') and b'Spriglet' not in response.read(1024 * 1024):
                raise ValueError(f'{route}: expected website content missing')
        print(f'PASS {route}')
    request = Request(origin.replace('https://', 'http://', 1) + '/support',
                      headers={'User-Agent': 'SprigletAvailability/1.0'})
    try:
        response = opener.open(request, timeout=30)
    except HTTPError as error:
        response = error
    with response:
        if response.status not in (301, 308) or response.headers.get('Location') != origin + '/support':
            raise ValueError('HTTP does not redirect to the expected HTTPS support page')
    print('PASS HTTP to HTTPS')


if __name__ == '__main__':
    main()
