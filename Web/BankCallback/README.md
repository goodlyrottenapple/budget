# Budget bank callback

Live callback:

https://budget-bank-callback-goodlyrottenapple.ank-allback.workers.dev/truelayer/callback

This is a static site deployed with Cloudflare Workers static assets. No token
exchange, database or application server runs on the host. A custom domain is
optional; a workers.dev hostname is enough. See the [root setup guide](../../README.md)
for TrueLayer credentials and the complete first-install sequence.

## Deploy

Install Node.js/npm and sign in to your Cloudflare account. For a separate
installation, change `name` in `wrangler.jsonc` before deploying. From the repository root:

```sh
npx --yes wrangler@4.134.0 login
npx --yes wrangler@4.134.0 deploy --config Web/BankCallback/wrangler.jsonc
```

Use the hostname printed by Wrangler, adding `/truelayer/callback`. Register
that exact URL in TrueLayer and set `App/Info.plist` → `BankCallbackURL`, then
rebuild the app. Redeploy with the same command after editing callback assets.

`public` is the entire published directory. Keep credentials, bank exports, and
app data out of it. Request observability is disabled. The return page forwards only code/state or error/state to the fixed Budget app
link, clears query parameters from its browser history entry, and makes no
analytics requests.
Infrastructure providers may still process URLs as part of serving requests.

## App configuration

- `App/Info.plist`: `BankCallbackURL` contains the registered HTTPS address.
- The same plist registers `com.personal.budgetr.auth` as a URL scheme.
- The website opens `com.personal.budgetr.auth://truelayer/callback`.
- The iPhone generates a fresh PKCE verifier for each attempt and keeps it in
  Keychain. Only its SHA-256 challenge appears in the authorisation URL.

The app currently uses an Apple Personal Team. A signed build confirmed this
team cannot use Associated Domains, so this implementation uses a custom-scheme
callback inside ASWebAuthenticationSession. No paid Apple membership is required.
The published association file is retained for a possible future Universal Links
setup, but the current app does not depend on it or request that entitlement.

If changing the hostname, update `BankCallbackURL`, this document, and TrueLayer's
allowlist together. The app callback scheme must also match `public/callback.js`.

## TrueLayer

The callback above must be registered under Budget's Application settings →
Redirect URIs. Keep `https://console.truelayer.com/redirect-page` registered for
the manual fallback, accessible in Developer Mode. Allow Console configuration changes to propagate before retrying.

## Behaviour

Connect/Reconnect opens system web authentication. TrueLayer redirects to the
registered HTTPS page, which opens Budget using its fixed app link. A visible
Open Budget button is available if the browser requires a user gesture.
Budget waits for the app to be unlocked, validates state, exchanges the code
with its PKCE verifier, validates the bank, saves tokens in Keychain, and syncs.

The pending request is stored in Keychain for up to 20 minutes, allowing the app
to receive the app link even after a restart. Callback destination, state and
parameter uniqueness are validated. The request is consumed before exchange,
preventing replay. Existing saved bank tokens remain if authorisation is
cancelled or declined. Starting a new flow invalidates the previous state.

The token exchange uses the original HTTPS redirect URI, not the app scheme.
No access token, refresh token, client secret or PKCE verifier goes to the site.

This implements automatic callbacks for connection/reconnection, not TrueLayer's
separate `/connections/extend` consent-renewal API.

## Verify

```sh
curl -i https://budget-bank-callback-goodlyrottenapple.ank-allback.workers.dev/.well-known/apple-app-site-association
curl -i https://budget-bank-callback-goodlyrottenapple.ank-allback.workers.dev/truelayer/callback
```

Both must return HTTPS 200 without redirects. The association file must be
`application/json`; the callback page must have `Cache-Control: no-store`.

The fake-bank tests cover callback validation, relaunch, expiry, rejection,
replay, and using the same redirect address for the token exchange:

```sh
swift test --filter BankServiceTests
node --test Web/BankCallback/callback.test.cjs
```

For the device check, install the new signed build, open a bank in Accounts and
choose Reconnect with bank. Authorise in the browser/bank app and verify Budget
returns automatically (or via Open Budget), unlocks, and updates that bank without copying a URL.
Also check browser cancellation and declining at the bank preserve existing data.

## Using another app URL scheme

If changing `com.personal.budgetr.auth`, update `CFBundleURLTypes` in
`App/Info.plist`, `BankService.appCallbackScheme`, `public/callback.js`, and the
callback tests together. Deploy the site and rebuild the app.
The `public/.well-known/apple-app-site-association` file is only relevant to a
future Universal Links setup; update its team/bundle identifier or remove it for
your deployment. It is not required for the current custom-scheme flow.
