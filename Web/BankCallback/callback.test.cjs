const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');
const script = fs.readFileSync(`${__dirname}/public/callback.js`, 'utf8');
function run(search) {
  const button = {hidden: true};
  const status = {};
  const redirects = [], history = [];
  vm.runInNewContext(script, {
    URL, URLSearchParams,
    location: {search, pathname: '/truelayer/callback', replace: url => redirects.push(url)},
    history: {replaceState: (...args) => history.push(args)},
    document: {getElementById: id => id === 'return' ? button : status}
  });
  return {button, status, redirects, history};
}
test('forwards the encoded code and state only to the fixed app callback', () => {
  const result = run('?code=a%2Bb%26c&state=nonce&redirect_uri=https://evil.example');
  const target = new URL(result.redirects[0]);
  assert.equal(target.protocol, 'com.personal.budgetr.auth:');
  assert.equal(target.hostname, 'truelayer');
  assert.equal(target.pathname, '/callback');
  assert.equal(target.searchParams.get('code'), 'a+b&c');
  assert.equal(target.searchParams.get('state'), 'nonce');
  assert.equal(target.searchParams.size, 2);
  assert.equal(result.button.hidden, false);
  assert.equal(result.button.href, target.href);
  assert.equal(result.history[0][2], '/truelayer/callback');
});
test('forwards cancellation without exposing an error description', () => {
  const result = run('?error=access_denied&state=nonce&error_description=details');
  const target = new URL(result.redirects[0]);
  assert.equal(target.searchParams.get('error'), 'access_denied');
  assert.equal(target.searchParams.size, 2);
});
test('rejects missing, duplicate, or ambiguous OAuth parameters', () => {
  for (const query of ['', '?code=x', '?state=s', '?state=&code=x', '?state=s&code=',
    '?state=s&state=t&code=x', '?state=s&code=x&code=y', '?state=s&error=e&code=x']) {
    const result = run(query);
    assert.equal(result.redirects.length, 0);
    assert.equal(result.button.hidden, true);
    assert.equal(result.history[0][2], '/truelayer/callback');
  }
});
