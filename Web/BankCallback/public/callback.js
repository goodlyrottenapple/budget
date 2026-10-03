// Only forward OAuth result parameters. The destination is fixed, never supplied
// by a query parameter. PKCE verification and state validation happen in Budget.
const incoming = new URLSearchParams(location.search);
history.replaceState(null, '', location.pathname);
const state = incoming.getAll('state');
const code = incoming.getAll('code');
const error = incoming.getAll('error');
if (state.length === 1 && state[0] &&
    ((code.length === 1 && code[0] && error.length === 0) ||
     (error.length === 1 && error[0] && code.length === 0))) {
  const target = new URL('com.personal.budgetr.auth://truelayer/callback');
  target.searchParams.set('state', state[0]);
  if (code.length) target.searchParams.set('code', code[0]);
  if (error.length) target.searchParams.set('error', error[0]);
  const button = document.getElementById('return');
  button.href = target.href;
  button.hidden = false;
  // Browsers may require the explicit button tap after switching bank apps.
  location.replace(target.href);
} else {
  document.getElementById('status').textContent = 'Open Budget and start connecting your bank there.';
}
