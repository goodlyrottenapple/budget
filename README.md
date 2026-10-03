# Budget

A personal iOS budgeting app built with SwiftUI and SwiftData. Connect UK bank accounts through TrueLayer, import Yonder transactions from CSV, and track monthly spending across accounts.

Features include pending transactions, recurring monthly bills, reimbursements, merchant name/icon rules, category budgets, local logo caching and optional Face ID protection. Financial data is stored on the device; there is no shared database or CloudKit sync.

## Requirements

- A Mac with Xcode supporting Swift 6 and the iOS 17+ deployment target.
- An iPhone for bank authorisation and background-refresh testing; a simulator works for UI/demo development.
- An Apple account for device signing. Select your own team in Xcode.
- A TrueLayer application with **live Data API access** and the banks you want enabled. Payment API credentials alone are not sufficient.
- A Cloudflare account and Node.js/npm to publish the HTTPS callback page.
- Optionally, a Logo.dev account for merchant icon search.

The checked-in app uses live TrueLayer endpoints. Sandbox credentials are not interchangeable with live credentials; switching environments requires changing the API/auth/provider endpoints as well.

## 1. Clone and configure the app

```sh
git clone https://github.com/goodlyrottenapple/budget.git
cd budget
open Budget.xcodeproj
```

Select the **Budget** target and set your signing team in **Signing & Capabilities**. Change the bundle identifier if needed. Choose your iPhone as the run destination.

The existing configuration belongs to this project's original deployment. For a separate deployment, update these values:

| Setting | Location |
| --- | --- |
| TrueLayer live client ID | `App/BankService.swift`, `clientID` |
| Provider catalogue client ID | `App/BudgetApp.swift`, URL in `loadProviders` |
| Diagnostic script client ID (if used) | `tools/verify_truelayer.py`, `CLIENT_ID` |
| HTTPS callback URL | `App/Info.plist`, `BankCallbackURL` |
| Cloudflare Worker name | `Web/BankCallback/wrangler.jsonc`, `name` |

Client IDs and callback addresses are public configuration. **Do not put API secrets or bank access/refresh tokens in source files.** Enter secrets in the installed app instead.

For normal use, select **Product → Scheme → Edit Scheme → Run → Build Configuration → Release**, then run on your device. Debug builds are intended for development and can be slower.

## 2. Obtain TrueLayer credentials

1. Sign in to [TrueLayer Console](https://console.truelayer.com/) and select/create your application in the **live** environment.
2. Confirm that the application has Data API access and the required live bank providers enabled. Availability depends on your TrueLayer access/agreement.
3. Open **Settings → Application settings**. Copy the client ID into the locations listed above.
4. Generate a client secret, completing the Console's authentication prompts. Save it securely; you will enter it on the phone, not in Cloudflare.
5. Deploy the callback in the next section, then add its exact HTTPS URL to **Redirect URIs** for this same application.
6. Optionally retain `https://console.truelayer.com/redirect-page` for the manual developer fallback.

Allow Console configuration changes to propagate before retrying. New client secrets can take up to 15 minutes to become usable. See [TrueLayer application settings](https://docs.truelayer.com/docs/application-settings) and [Data API auth links](https://docs.truelayer.com/docs/generate-an-auth-link).

On the phone, open **Accounts → API Credentials → TrueLayer** and save the live client secret. This one secret is shared across your bank connections; each bank gets its own authorisation and access/refresh tokens.

## 3. Deploy the Cloudflare callback

The callback is a **static site hosted by Cloudflare Workers**, not a server that exchanges tokens. No database, Worker secrets or custom domain are required. A Cloudflare `workers.dev` address is sufficient.

From the repository root:

```sh
npx --yes wrangler@4.134.0 login
```

Sign in to your Cloudflare account in the browser. If making your own deployment, change `name` in `Web/BankCallback/wrangler.jsonc` to your chosen Worker name, then run:

```sh
npx --yes wrangler@4.134.0 deploy --config Web/BankCallback/wrangler.jsonc
```

Use the hostname printed by Wrangler and append `/truelayer/callback`:

```text
https://<worker-name>.<your-workers-subdomain>.workers.dev/truelayer/callback
```

Set this **exact same URL** in both:

- TrueLayer Console → your live application → Settings → Application settings → Redirect URIs.
- `App/Info.plist` → `BankCallbackURL`.

Rebuild/install the app after changing the plist. The current original deployment is:

```text
https://budget-bank-callback-goodlyrottenapple.ank-allback.workers.dev/truelayer/callback
```

Test your own address:

```sh
curl -i https://<worker-name>.<your-workers-subdomain>.workers.dev/truelayer/callback
node --test Web/BankCallback/callback.test.cjs
```

The page should return HTTPS 200 and `Cache-Control: no-store`. Visiting without an authorisation code should show the callback page's missing/invalid callback message, rather than connect a bank.

Run the same deploy command to publish callback updates. Only `Web/BankCallback/public` is uploaded. See the [callback deployment guide](Web/BankCallback/README.md) for URL-scheme configuration and troubleshooting, and [Cloudflare's static assets guide](https://developers.cloudflare.com/workers/static-assets/get-started/) for hosting details.

## 4. Connect your banks

1. Save the TrueLayer client secret in the app as described above.
2. In **Accounts**, tap **+**, select a bank, then open its connection screen.
3. Start the bank authorisation flow and approve access in the browser/bank app.
4. The HTTPS callback opens Budget automatically. If prompted, tap **Open Budget** and unlock the app.
5. Budget validates the callback and imports the selected bank's accounts/cards and transactions.
6. Repeat for each bank. Do not reuse another bank's access token.

Pull down in Overview or Accounts to sync. A bank's detail screen also has a sync control. When consent expires or a bank requires renewed access, use **Reconnect with bank** and repeat the approval journey; normal reconnection does not require copying a URL.

### How the callback and tokens work

```text
Budget → TrueLayer/bank approval → HTTPS Cloudflare page
       → com.personal.budgetr.auth://truelayer/callback → Budget
       → TrueLayer token exchange → bank data sync
```

Budget creates a random state and PKCE challenge. The pending request is kept in Keychain for up to 20 minutes. The static page forwards the authorisation code/state (or error/state) to the fixed app URL scheme and clears its browser-history query string. Budget validates the response and exchanges the code using the original HTTPS redirect URI and PKCE verifier.

The callback host receives the redirect containing the short-lived authorisation code; it does **not** receive the client secret, PKCE verifier, access token or refresh token. Hosting infrastructure still processes requests. The page has no analytics and Worker observability is disabled.

The app saves the shared TrueLayer secret and per-bank tokens in iOS Keychain. Access tokens refresh automatically when possible. A failed or cancelled reconnection retains previously imported history. This is a personal-use direct integration; a distributed production app should move confidential client credentials/token exchange to a backend.

## 5. Optional Logo.dev merchant search

1. Create/sign in to your account at [Logo.dev](https://www.logo.dev/), then open its dashboard and API key settings.
2. Obtain the **secret key** beginning `sk_`. The `pk_` publishable image key is not the key this app's brand search expects.
3. In Budget, open **Accounts → API Credentials → Logo.dev**, enter the secret key and save.
4. Edit a transaction's merchant name. After you pause typing, remote icon suggestions appear beneath local merchant suggestions.

The implementation uses `api.logo.dev/search` with bearer authentication. Check your account's current search entitlement/limits in the dashboard. See the [official Logo.dev API repository](https://github.com/logo-dev/logo-api) for API and dashboard links.

You can also choose a custom icon from photos/files without Logo.dev. Downloaded merchant icons are cached locally for offline use; unused cached icons are cleaned up. The Logo.dev key is stored in Keychain, never on the callback site.

## Offline Yonder imports

Open **Accounts → Offline Accounts → Yonder → Import**, choose a CSV, review the preview and confirm. Yonder's native export is recognised by its `Date/Time of transaction` and `Amount (GBP)` headers; settled GBP amounts are used for foreign purchases.

A generic format is also supported; see [the synthetic example](Fixtures/yonder-example.csv):

```csv
date,description,amount,currency,account,id,category
2026-09-12,Coffee,-4.50,GBP,Yonder,example-1,Dining
```

Required columns are `date,description,amount`. Dates use `YYYY-MM-DD`; spending is negative and received funds positive. Optional columns are `currency,account,id,category`. Include unique IDs for otherwise identical purchases: without IDs, identical same-day rows can be treated as duplicates. Classify card repayments as Transfer to exclude them from spending.

Yonder's displayed balance is calculated from imported transactions in the current month, assuming a zero opening balance. It is not a live bank balance. Budgets use the currency selected in **Overview → Budget → Edit**. The currency dropdown appears only when multiple currencies are detected in accounts or transactions. With a single currency, that currency is used automatically. Changing currency retains the entered limits without converting them. Current balances show a separate total for each currency; amounts are never combined across currencies.

## Sync, storage and app settings

- Bank sync fetches approximately the last 90 days while retaining older imported history. Pending transactions are refreshed as snapshots and reconciled with settled payments where identifiers/matches allow. A disappearing pending payment may not yet be available as settled through TrueLayer.
- Automatic foreground sync checks for banks last synced at least six hours ago; failed automatic attempts have a retry cooldown. Manual pull-to-sync bypasses these time checks.
- Periodic background refresh requests a run no earlier than six hours later. **iOS chooses the actual time**; it is not a guaranteed six-hour schedule. Enable Background App Refresh in iOS. Force-quitting, Low Power Mode and system scheduling can prevent/delay runs.
- Transactions, budgets and rules live in the local SwiftData store. Keep the same app identity when updating to retain data; deleting the app removes its local database. This app does not provide family sharing or a remote backup.
- TrueLayer credentials and database protection allow background work after the device's first unlock following a restart. The pending authorisation request and Logo.dev key require an unlocked device. Credentials use device-only Keychain protection.
- In **iOS Settings → Apps → Budget** (or Settings → Budget), enable **Require Face ID**, **Developer Mode**, or **Demo Data**. Demo mode uses isolated sample data and disables real bank sync. Developer Mode exposes manual tokens and diagnostic sections.
- Face ID/device authentication protects the UI, with an inactivity grace period; it does not replace the device's storage encryption.

## Development and verification

```sh
swift test
node --test Web/BankCallback/callback.test.cjs
xcodebuild -project Budget.xcodeproj -scheme Budget \
  -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath DerivedData build
```

The device build needs a configured signing team. The tests cover core calculations, persistence, bank reconciliation, authentication and callback validation. Background scheduling and the complete bank-app handoff need a physical-device check.

`tools/verify_truelayer.py` and `tools/verify_logo_dev.py` provide interactive API diagnostics with hidden credential prompts. Inspect their options with `--help`; configure the TrueLayer script's client ID for your application. Never commit downloaded bank responses, CSV exports or credentials.

| Directory | Purpose |
| --- | --- |
| `App/` | SwiftUI app, bank service, lock screen, assets and iOS settings |
| `Sources/BudgetCore/` | Budget calculations, import and reconciliation logic |
| `Sources/BudgetPersistence/` | SwiftData persistence |
| `Tests/` | Swift tests and fake bank fixtures |
| `Web/BankCallback/` | Static HTTPS callback and deployment configuration |
| `Fixtures/` | Synthetic example CSV |
| `tools/` | Local diagnostics and asset helpers |

Bank artwork provenance is recorded in [App/BankIcons/SOURCES.md](App/BankIcons/SOURCES.md). Included font licensing is under `tools/fonts/`.

## Troubleshooting

| Symptom | Check |
| --- | --- |
| Redirect rejected | Exact HTTPS URL matches TrueLayer's live app allowlist and `BankCallbackURL`, including path/trailing slash. |
| Callback opens but app does not | App is installed; URL scheme matches the callback script. Tap Open Budget if the browser requires a gesture. |
| Token exchange fails | Correct live client ID/secret pair; fresh authorisation attempt; the code is single-use. |
| Wrong bank/no accounts | Authorise that bank separately and check granted account/card scopes and provider availability. |
| Callback HTTPS/TLS error | Confirm the deployed hostname in Wrangler/Cloudflare and its certificate status. Allow new hostname provisioning to finish; do not disable TLS validation. |
| Logo search fails | Use the `sk_` secret, check search access/quota and network availability. |
| A settled transaction is missing | Sync again later; banks and TrueLayer may publish settled data at different times. Developer diagnostics can inspect what TrueLayer returns. |
| Background refresh does not run on schedule | iOS controls scheduling; check Background App Refresh, power state and that the app has not been force-quit. |
