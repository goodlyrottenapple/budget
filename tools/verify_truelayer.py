#!/usr/bin/env python3
"""Read-only TrueLayer Data v1 live probe. Secrets and bank data stay in memory."""
import argparse
import getpass
import json
import re
import sys
from datetime import datetime, timedelta, timezone
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, quote, urlsplit, parse_qs
from urllib.request import Request, urlopen

CLIENT_ID = 'budget-2f2bbc'
REDIRECT_URI = 'https://console.truelayer.com/redirect-page'


class APIError(Exception):
    pass


def extract_code(value):
    value = value.strip()
    if value.startswith(('https://', 'http://')):
        parsed = urlsplit(value)
        redirect = urlsplit(REDIRECT_URI)
        if (parsed.scheme, parsed.netloc, parsed.path) != (redirect.scheme, redirect.netloc, redirect.path):
            raise ValueError('Redirect URL does not match the registered test redirect URI.')
        codes = parse_qs(parsed.query).get('code', [])
        if len(codes) != 1 or not codes[0]:
            raise ValueError('Redirect URL must contain exactly one code.')
        return codes[0]
    return value


def request(url, token=None, form=None):
    headers = {'Accept': 'application/json'}
    if token:
        headers['Authorization'] = 'Bearer ' + token
    body = None
    if form is not None:
        headers['Content-Type'] = 'application/x-www-form-urlencoded'
        body = urlencode(form).encode()
    try:
        with urlopen(Request(url, data=body, headers=headers), timeout=45) as response:
            return json.load(response)
    except HTTPError as error:
        # Only expose a short machine-readable identifier, never descriptions,
        # response bodies, tokens, or submitted credentials.
        identifier = None
        try:
            payload = json.loads(error.read(65536))
            candidate = payload.get('error') if isinstance(payload, dict) else None
            if isinstance(candidate, str) and re.fullmatch(r'[a-z_]{1,64}', candidate):
                identifier = candidate
        except (ValueError, OSError):
            pass
        suffix = f' ({identifier})' if identifier else ''
        raise APIError(f'HTTP {error.code}{suffix}') from None
    except URLError:
        raise APIError('Network connection failed') from None
    except (ValueError, TimeoutError):
        raise APIError('Invalid response or request timeout') from None


def raw_examples(payload, count, match=None):
    rows = payload['results']
    if match:
        rows = [row for row in rows if match.casefold() in str(row.get('description', '')).casefold()]
    # Retain unknown fields and the original envelope, changing only result count.
    return {**payload, 'results': rows[:count]}


def print_transaction_fields(rows):
    fields = sorted({key for row in rows for key in row})
    meta_fields = sorted({key for row in rows if isinstance(row.get('meta'), dict) for key in row['meta']})
    print('Transaction fields:', ', '.join(fields) or '(none)')
    print('Provider meta fields:', ', '.join(meta_fields) or '(none)')
    print('Transactions with merchant_name:', sum(bool(row.get('merchant_name')) for row in rows))
    print('Transactions with normalised_provider_transaction_id:', sum(bool(row.get('normalised_provider_transaction_id')) for row in rows))


def main():
    parser = argparse.ArgumentParser(description='Privately verify TrueLayer or inspect raw transaction responses.')
    parser.add_argument('--access-token', action='store_true', help='Privately prompt for an existing token instead of exchanging a code.')
    parser.add_argument('--only-cards', action='store_true', help='Only check credit cards (use for Amex).')
    parser.add_argument('--provider-summary', action='store_true', help='Print only provider IDs and counts from account/card lists. No account identifiers or transactions.')
    parser.add_argument('--raw-transactions', type=int, metavar='N', help='Print up to N complete transaction objects per account/card, with the response envelope. Private output: includes financial data.')
    parser.add_argument('--match', help='Limit raw examples to descriptions containing this text, e.g. AMAZON.')
    args = parser.parse_args()
    if args.raw_transactions is not None and not 1 <= args.raw_transactions <= 100:
        parser.error('--raw-transactions must be between 1 and 100')
    if not sys.stdin.isatty():
        print('Run this interactively in your own Terminal for hidden secret prompts.')
        return 1
    print('TrueLayer LIVE verification. No secrets, tokens, or bank data are saved.')
    if args.raw_transactions:
        print('Raw mode prints private financial data in your Terminal. Credentials are never printed.')
    if args.access_token:
        token = getpass.getpass('Access token only (hidden): ').strip()
        if not token or any(c.isspace() for c in token):
            print('Enter the access token without the Bearer prefix.')
            return 1
    else:
        secret = getpass.getpass('Live client secret (hidden): ').strip()
        print('Codes expire after 5 minutes. Authorise again now if needed, then paste immediately.')
        try:
            code = extract_code(getpass.getpass('Code shown on the page, or full redirect URL (hidden): '))
        except ValueError as error:
            print(str(error))
            return 1
        if not secret or not code:
            print('Both values are required.')
            return 1
        try:
            response = request('https://auth.truelayer.com/connect/token', form={
                'grant_type': 'authorization_code', 'client_id': CLIENT_ID,
                'client_secret': secret, 'redirect_uri': REDIRECT_URI, 'code': code,
            })
        except APIError as error:
            print(f'Token exchange failed: {error}. Check Live credentials and the exact redirect URI.')
            print('If the code expired or was already used, authorise again for a fresh code.')
            return 1
        token = response.get('access_token')
        if not isinstance(token, str) or not token:
            print('Token exchange did not return an access token.')
            return 1
        del secret, code, response
        print('PASS: token exchange')
    end = datetime.now(timezone.utc)
    query = urlencode({'from': (end - timedelta(days=90)).isoformat(), 'to': end.isoformat()})
    checked = 0
    failures = 0
    for kind in (('cards',) if args.only_cards else ('accounts', 'cards')):
        try:
            items = request(f'https://api.truelayer.com/data/v1/{kind}', token)['results']
            if not isinstance(items, list):
                raise ValueError()
        except (APIError, KeyError, ValueError) as error:
            print(f'{kind}: unavailable ({error if isinstance(error, APIError) else "unexpected response"}); this may be unsupported by this connection.')
            continue
        print(f'PASS: {kind} list ({len(items)} returned)')
        if args.provider_summary:
            providers = {}
            for item in items:
                provider = item.get('provider')
                provider_id = provider.get('provider_id') if isinstance(provider, dict) else None
                key = provider_id if isinstance(provider_id, str) and provider_id else '(missing provider ID)'
                providers[key] = providers.get(key, 0) + 1
            print(f'{kind} provider IDs: ' + (', '.join(f'{key}: {providers[key]}' for key in sorted(providers)) or '(none)'))
            checked += len(items)
            continue
        for index, item in enumerate(items, 1):
            account_id = item.get('account_id')
            if not isinstance(account_id, str) or not account_id:
                failures += 1
                print(f'{kind} #{index}: missing account ID')
                continue
            checked += 1
            base = f'https://api.truelayer.com/data/v1/{kind}/{quote(account_id, safe="")}'
            for label, path in [('balance', '/balance'), ('transactions (90-day request)', '/transactions?' + query)]:
                try:
                    payload = request(base + path, token)
                    results = payload['results']
                    if not isinstance(results, list):
                        raise ValueError()
                    print(f'PASS: {kind} #{index} {label} ({len(results)} records)')
                    if path.startswith('/transactions'):
                        print_transaction_fields(results)
                        if args.raw_transactions:
                            examples = raw_examples(payload, args.raw_transactions, args.match)
                            print(f'RAW: {kind} #{index} transaction response (results limited to {len(examples["results"])} examples)')
                            print(json.dumps(examples, indent=2, ensure_ascii=False))
                except (APIError, KeyError, ValueError) as error:
                    failures += 1
                    print(f'FAIL: {kind} #{index} {label} ({error if isinstance(error, APIError) else "unexpected response"})')
    if not checked:
        print('Not validated: no account or card was available to probe.')
        return 1
    if failures:
        print('Partially validated: some balance or transaction checks failed.')
        return 1
    print('Validated: balance and transaction endpoints responded for every returned account/card.')
    print('Empty transaction results do not prove that transaction history is available.')
    print('Share only summary lines or manually anonymised raw examples. Never share credentials.')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (KeyboardInterrupt, EOFError):
        print('\nCancelled.')
        sys.exit(1)
