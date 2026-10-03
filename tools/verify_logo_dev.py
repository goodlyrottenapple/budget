#!/usr/bin/env python3
"""One Brand Search request, no dependencies, no saved keys or financial data."""
import argparse
import getpass
import json
import re
import sys
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlsplit, urlunsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

ENDPOINT = 'https://api.logo.dev/search'

class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None

def safe_text(value, key):
    text = str(value).replace(key, '[redacted]') if key else str(value)
    text = re.sub(r'\b(?:sk_|pk_)[A-Za-z0-9_.-]+', '[redacted]', text)
    text = re.sub(r'(?i)(token|api_key|access_token|secret)=([^\s&"<>]+)', r'\1=[redacted]', text)
    return ''.join(c for c in text if c.isprintable())[:1000]

def report(status, content_type, body, key):
    print(f'HTTP: {status}')
    print('Content-Type:', safe_text(content_type, key))
    try:
        payload = json.loads(body)
    except (ValueError, UnicodeDecodeError):
        print('Response format: non-JSON')
        # Avoid dumping HTML/error bodies which could echo the query or credentials.
        print('Body omitted. This is not the documented Brand Search response.')
        return 1
    if isinstance(payload, list):
        print(f'Response format: array ({len(payload)} candidates)')
    elif isinstance(payload, dict):
        print('Response format: object; fields:', ', '.join(safe_text(k, key) for k in payload))
        for field in ('error', 'message', 'code'):
            if isinstance(payload.get(field), (str, int)):
                print(f'{field}: {safe_text(payload[field], key)}')
    else:
        print('Response format:', type(payload).__name__)
    if status != 200:
        print({401: 'API key rejected. Use the secret sk_ key.',
               402: 'Account allowance or payment required.',
               403: 'Access denied. Check key permissions and account access.',
               404: 'Endpoint returned 404; this does not establish that the retailer is absent.',
               429: 'Rate limit reached. Try later.'}.get(status, 'API request failed.'))
        return 1
    if not isinstance(payload, list):
        print('Unexpected schema: Brand Search should return an array.')
        return 1
    if not payload:
        print('Search succeeded but found no candidates. Try a shorter retailer name.')
        return 0
    for index, item in enumerate(payload[:10], 1):
        if not isinstance(item, dict):
            print('Unexpected candidate schema.')
            return 1
        print(f'Candidate {index}:')
        print('  Name:', safe_text(item.get('name', '(missing)'), key))
        print('  Domain:', safe_text(item.get('domain', '(missing)'), key))
        logo = item.get('logo_url')
        if isinstance(logo, str):
            parsed = urlsplit(logo)
            # Logo URLs contain publishable tokens; never print their query strings.
            clean = urlunsplit((parsed.scheme, parsed.netloc, parsed.path, '', ''))
            print('  Logo (query omitted):', safe_text(clean, key))
        else:
            print('  Logo: not supplied')
    print('Categories: not supplied by Brand Search.')
    return 0

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sample', action='store_true', help='Search for Starbucks as a public baseline.')
    args = parser.parse_args()
    if not sys.stdin.isatty():
        print('Run in your own interactive Terminal for hidden prompts.')
        return 1
    key = getpass.getpass('Logo.dev secret key (sk_, hidden): ').strip()
    if not key.startswith('sk_') or any(c.isspace() for c in key):
        print('Use your secret sk_ key, not the publishable pk_ key.')
        return 1
    query = 'Starbucks' if args.sample else getpass.getpass('Retailer name or shortened descriptor (hidden): ').strip()
    if not query:
        print('A retailer name is required.')
        return 1
    request = Request(ENDPOINT + '?' + urlencode({'q': query, 'strategy': 'match'}),
                      headers={'Authorization': 'Bearer ' + key, 'Accept': 'application/json'})
    print('Request: GET https://api.logo.dev/search (query omitted), strategy=match')
    try:
        with build_opener(NoRedirect()).open(request, timeout=30) as response:
            return report(response.status, response.headers.get('Content-Type', ''), response.read(65536), key)
    except HTTPError as error:
        return report(error.code, error.headers.get('Content-Type', ''), error.read(65536), key)
    except (URLError, TimeoutError, OSError):
        print('Network request failed or timed out. No request credentials were printed.')
        return 1

if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nCancelled.')
        sys.exit(1)
