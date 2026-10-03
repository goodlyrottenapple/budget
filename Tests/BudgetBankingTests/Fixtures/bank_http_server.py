"""Local fake Data API: deliberately cacheable responses, no real credentials."""
import json
import re
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def respond(self, body, status=200):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        # Deliberately omit Vary: Authorization, just as in the cache reproduction.
        self.send_header('Cache-Control', 'max-age=3600')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        form = parse_qs(self.rfile.read(int(self.headers['Content-Length'])).decode())
        if urlsplit(self.path).path != '/connect/token':
            return self.respond({}, 404)
        if form.get('grant_type') == ['refresh_token']:
            provider = form['refresh_token'][0].removeprefix('refresh-').removesuffix('-v1')
            version = 'v2'
        else:
            provider = form['code'][0]
            if provider == 'ob-callback-test' and form.get('redirect_uri') != ['https://budget.example/truelayer/callback']:
                return self.respond({'error': 'redirect_uri_mismatch'}, 400)
            if provider == 'ob-callback-test' and not re.fullmatch(r'[A-Za-z0-9_-]{43}', form.get('code_verifier', [''])[0]):
                return self.respond({'error': 'missing_pkce_verifier'}, 400)
            version = 'v1'
        self.respond({'access_token': f'test-{provider}-{version}',
                      'refresh_token': f'refresh-{provider}-{version}',
                      'expires_in': 3600, 'scope': 'accounts cards balance transactions offline_access'})

    def do_GET(self):
        token = self.headers.get('Authorization', '').removeprefix('Bearer ')
        provider = re.sub(r'-v\d+$', '', token.removeprefix('test-'))
        path = urlsplit(self.path).path
        if path.endswith('/balance'):
            return self.respond({'results': [{'current': 100, 'currency': 'GBP'}]})
        if path.endswith('/transactions/pending'):
            if urlsplit(self.path).query:
                return self.respond({'error': 'pending_must_not_have_date_filter'}, 400)
            if provider == 'ob-pending-error':
                return self.respond({'error': 'provider_unavailable'}, 503)
            if provider == 'ob-pending-unsupported':
                return self.respond({'error': 'endpoint_not_supported'}, 501)
            date = (datetime.now(timezone.utc) - timedelta(days=100)).isoformat()
            return self.respond({'results': [{'transaction_id': 'pending-1',
                'timestamp': date, 'description': 'Pending purchase', 'amount': 3,
                'currency': 'GBP', 'transaction_type': 'DEBIT', 'transaction_category': 'PURCHASE'}]})
        if path.endswith('/transactions'):
            date = (datetime.now(timezone.utc) - timedelta(minutes=1)).isoformat()
            return self.respond({'results': [{'transaction_id': 'tx-1',
                'normalised_provider_transaction_id': 'stable-1', 'timestamp': date,
                'description': 'Test purchase', 'amount': 10, 'currency': 'GBP',
                'transaction_type': 'DEBIT', 'transaction_category': 'PURCHASE'}]})
        if path not in ['/data/v1/accounts', '/data/v1/cards']:
            return self.respond({}, 404)
        if provider == 'empty':
            return self.respond({'results': []})
        if (provider == 'ob-amex') != path.endswith('/cards'):
            return self.respond({'results': []})
        account = {'account_id': provider + '-account', 'currency': 'GBP', 'display_name': provider}
        if provider != 'missing-provider':
            account['provider'] = {'provider_id': provider}
        self.respond({'results': [account]})


server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
