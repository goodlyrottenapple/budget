import Foundation
import Security
import CryptoKit
#if SWIFT_PACKAGE
import BudgetCore
#endif

enum BankKeychain {
    static let service = "com.personal.budgetr.truelayer"
    static func read(_ account: String, service: String = BankKeychain.service) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account,
            kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw CSVError.invalid("Could not read saved credentials from Keychain.")
        }
        if service == BankKeychain.service, account != "pending-authorisation" {
            // Migrate existing bank credentials after a successful unlocked read.
            let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service, kSecAttrAccount as String: account]
            SecItemUpdate(item as CFDictionary,
                [kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly] as CFDictionary)
        }
        return data
    }
    static func write(_ data: Data, account: String, service: String = BankKeychain.service) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: service == BankKeychain.service && account != "pending-authorisation"
                ? kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly : kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            guard SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil) == errSecSuccess else {
                throw CSVError.invalid("Could not save saved credentials to Keychain.")
            }
        } else if status != errSecSuccess {
            throw CSVError.invalid("Could not save saved credentials to Keychain.")
        }
    }
    static func remove(_ account: String) throws {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: account]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CSVError.invalid("Could not remove saved credentials from Keychain.")
        }
    }
}

// Refuse redirects so an API request can never forward credentials to another host.
final class BankSessionDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

@MainActor
final class BankService {
    struct WrongBankToken: LocalizedError {
        let bank: String
        let returned: String
        var errorDescription: String? {
            "This token is not authorised for \(bank). It returned \(returned). Reauthorise \(bank) and connect it again."
        }
    }
    static let clientID = "budget-2f2bbc"
    nonisolated static let redirectURI = "https://console.truelayer.com/redirect-page"
    nonisolated static let appCallbackScheme = "com.personal.budgetr.auth"
    static var automaticRedirectURI: String? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "BankCallbackURL") as? String,
              let url = URLComponents(string: value), url.scheme == "https", url.host != nil,
              url.path == "/truelayer/callback", url.query == nil, url.fragment == nil else { return nil }
        return value
    }
    struct Authorisation: Codable {
        let provider: BankProvider
        let state: String
        let redirectURI: String
        let startedAt: Date
        let codeVerifier: String
    }
    private static let authorisationKey = "pending-authorisation"

    func beginAuthorisation(_ provider: BankProvider, redirectURI: String, now: Date = Date()) throws -> URL {
        var random = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, random.count, &random) == errSecSuccess else {
            throw CSVError.invalid("Could not securely start bank authorisation. Please try again.")
        }
        let verifier = Self.base64URL(Data(random))
        let request = Authorisation(provider: provider, state: UUID().uuidString,
                                    redirectURI: redirectURI, startedAt: now, codeVerifier: verifier)
        let challenge = Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
        guard let url = provider.authorisationURL(clientID: Self.clientID, redirectURI: redirectURI,
                                                  state: request.state, codeChallenge: challenge) else {
            throw CSVError.invalid("Could not start bank authorisation.")
        }
        try writeSecret(JSONEncoder().encode(request), Self.authorisationKey)
        return url
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    func cancelAuthorisation() throws { try removeSecret(Self.authorisationKey) }

    func pendingAuthorisation() throws -> Authorisation? {
        guard let data = try readSecret(Self.authorisationKey) else { return nil }
        return try JSONDecoder().decode(Authorisation.self, from: data)
    }

    func completeAuthorisation(_ callback: URL, now: Date = Date()) async throws -> BankProvider {
        guard let pending = try pendingAuthorisation() else {
            throw CSVError.invalid("This bank authorisation is no longer active. Connect the bank again.")
        }
        guard (0...1200).contains(now.timeIntervalSince(pending.startedAt)) else {
            try cancelAuthorisation()
            throw CSVError.invalid("This bank authorisation has expired. Connect the bank again.")
        }
        // Validate before consuming the request. Unrelated links must not cancel a genuine flow.
        _ = try Self.validateAuthorisationCallback(callback.absoluteString, redirectURI: pending.redirectURI, expectedState: pending.state)
        try cancelAuthorisation() // Consume once, before the first suspension/token exchange.
        try await connect(pending.provider, code: callback.absoluteString, expectedState: pending.state,
                          redirectURI: pending.redirectURI, codeVerifier: pending.codeVerifier)
        return pending.provider
    }
    private let session: URLSession
    private let dataURL: URL
    private let tokenURL: URL
    private let readSecret: (String) throws -> Data?
    private let writeSecret: (Data, String) throws -> Void
    private let removeSecret: (String) throws -> Void

    init(dataURL: URL = URL(string: "https://api.truelayer.com/data/v1")!,
         tokenURL: URL = URL(string: "https://auth.truelayer.com/connect/token")!,
         readSecret: @escaping (String) throws -> Data? = { try BankKeychain.read($0) },
         writeSecret: @escaping (Data, String) throws -> Void = { try BankKeychain.write($0, account: $1) },
         removeSecret: @escaping (String) throws -> Void = { try BankKeychain.remove($0) }) {
        self.dataURL = dataURL; self.tokenURL = tokenURL
        self.readSecret = readSecret; self.writeSecret = writeSecret; self.removeSecret = removeSecret
        // Ephemeral sessions still cache in RAM. A cacheable /accounts or /cards
        // response can be reused across different bearer tokens at the same URL.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 90
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration, delegate: BankSessionDelegate(), delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    struct Credential: Codable {
        var accessToken: String
        var refreshToken: String?
        var expiresAt: Date?
        var scopes: [String]
        var accounts: [BankAccount] = []
        var syncedAt: String?
        var categoryReport: String?
    }
    private struct TokenResponse: Decodable {
        let access_token: String
        let refresh_token: String?
        let expires_in: Int
        let scope: String?
    }
    private struct Results<T: Decodable>: Decodable { let results: [T] }
    private struct Account: Decodable {
        let account_id: String
        let display_name: String?
        let currency: String
        let partial_card_number: String?
        let provider: Provider?
        struct Provider: Decodable { let provider_id: String }
    }
    private struct Balance: Decodable { let current: Decimal; let currency: String }
    private struct Transaction: Decodable {
        let transaction_id: String
        let normalised_provider_transaction_id: String?
        let timestamp: String
        let description: String?
        let amount: Decimal
        let currency: String
        let transaction_type: String
        let transaction_category: String?
        let transaction_classification: [String]?
        let merchant_name: String?
        let meta: Metadata?
        struct Metadata: Decodable { let provider_merchant_name: String? }
        var retailerName: String? {
            [merchant_name, meta?.provider_merchant_name].compactMap { value -> String? in
                guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
                return name
            }.first
        }
    }

    var hasClientSecret: Bool { (try? readSecret("client-secret")) != nil }
    func savedClientSecret() throws -> String {
        guard let data = try readSecret("client-secret") else { return "" }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CSVError.invalid("The saved TrueLayer client secret could not be read.")
        }
        return value
    }
    func saveClientSecret(_ value: String) throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        try writeSecret(Data(value.utf8), "client-secret")
    }
    func credential(_ providerID: String) throws -> Credential? {
        guard let data = try readSecret(providerID) else { return nil }
        return try JSONDecoder().decode(Credential.self, from: data)
    }
    private func save(_ credential: Credential, providerID: String) throws {
        try writeSecret(JSONEncoder().encode(credential), providerID)
    }
    private func validateOwnership(token: String, scopes: [String], provider: BankProvider) async throws {
        var returned: [Account] = []
        let kinds = ["accounts", "cards"].filter { scopes.contains($0) && provider.scopes.contains($0) }
        for kind in kinds {
            let listed: Results<Account> = try await request(dataURL.appendingPathComponent(kind), token: token)
            if listed.results.contains(where: { provider.matchesAccountProviderID($0.provider?.provider_id) }) { return }
            returned += listed.results
        }
        throw accountSelectionError(provider: provider, kinds: kinds, returned: returned)
    }
    private func accountSelectionError(provider: BankProvider, kinds: [String], returned: [Account]) -> Error {
        guard !kinds.isEmpty else {
            return CSVError.invalid("The saved permissions do not include accounts or cards supported by \(provider.name). Reconnect to grant access.")
        }
        guard !returned.isEmpty else {
            return CSVError.invalid("TrueLayer returned an empty account/card list for \(provider.name). Your saved transactions are unchanged. Try syncing again shortly.")
        }
        guard returned.allSatisfy({ $0.provider?.provider_id.isEmpty == false }) else {
            return CSVError.invalid("TrueLayer returned accounts without a bank identifier. They could not be matched safely. Your saved transactions are unchanged.")
        }
        let ids = Set(returned.compactMap { $0.provider?.provider_id }).sorted().joined(separator: ", ")
        return WrongBankToken(bank: provider.name, returned: "accounts from " + ids)
    }
    func forget(_ providerID: String) throws { try removeSecret(providerID) }

    private struct PendingNotSupported: Error {}

    private func request<T: Decodable>(_ url: URL, token: String? = nil, form: [String: String]? = nil) async throws -> T {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 45
        request.setValue("no-cache, no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let form {
            request.httpMethod = "POST"
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
            request.httpBody = form.sorted { $0.key < $1.key }.map {
                "\($0.key.addingPercentEncoding(withAllowedCharacters: allowed)!)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed)!)"
            }.joined(separator: "&").data(using: .utf8)
        }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard response.statusCode == 200 else {
            if url.path.hasSuffix("/transactions/pending") {
                let error = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                if response.statusCode == 501 || error?["error"] as? String == "endpoint_not_supported" {
                    throw PendingNotSupported()
                }
            }
            switch response.statusCode {
            case 202: throw CSVError.invalid("Bank data is still being prepared. Try syncing again shortly.")
            case 400: throw CSVError.invalid("TrueLayer rejected the request. If exchanging a code, use a fresh code and check your client secret.")
            case 401, 403: throw CSVError.invalid("Bank access expired or was denied. Reconnect this bank or replace its access token.")
            case 429: throw CSVError.invalid("The bank's request limit was reached. Try again later.")
            default: throw CSVError.invalid("TrueLayer request failed (HTTP \(response.statusCode)). Try again.")
            }
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    private func token(_ form: [String: String]) async throws -> TokenResponse {
        guard let data = try readSecret("client-secret"), let secret = String(data: data, encoding: .utf8), !secret.isEmpty else {
            throw CSVError.invalid("Enter your TrueLayer client secret once to exchange or refresh tokens, or paste an existing access token.")
        }
        return try await request(tokenURL,
            form: form.merging(["client_id": Self.clientID, "client_secret": secret]) { _, new in new })
    }
    static func validateAuthorisationCallback(_ input: String, redirectURI: String, expectedState: String?) throws -> URLComponents {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let expectedState else {
            throw CSVError.invalid("Tap Authorise with bank first, then paste its full redirect URL.")
        }
        guard let expected = URLComponents(string: redirectURI),
              var url = URLComponents(string: input) else {
            throw CSVError.invalid("Invalid bank callback.")
        }
        if url.scheme == appCallbackScheme, url.host == "truelayer", url.path == "/callback",
           url.port == nil, url.user == nil, url.password == nil, url.fragment == nil,
           expected.path == "/truelayer/callback" {
            // The static HTTPS page forwards only OAuth result parameters to our app link.
            // Token exchange still uses the exact HTTPS redirect from the original request.
            let query = url.percentEncodedQuery
            url = expected
            url.percentEncodedQuery = query
        }
        guard url.scheme == "https",
              url.host == expected.host, url.port == expected.port, url.path == expected.path,
              url.user == nil, url.password == nil, url.fragment == nil else {
            throw CSVError.invalid("The bank callback does not match this authorisation’s return address.")
        }
        let states = url.queryItems?.filter { $0.name == "state" } ?? []
        guard states.count == 1, states.first?.value == expectedState else {
            throw CSVError.invalid("This redirect belongs to another authorisation. Start again with this bank.")
        }
        return url
    }
    static func authorisationCode(_ input: String, redirectURI: String, expectedState: String?) throws -> String {
        let url = try validateAuthorisationCallback(input, redirectURI: redirectURI, expectedState: expectedState)
        if url.queryItems?.contains(where: { $0.name == "error" }) == true {
            throw CSVError.invalid("Bank authorisation was cancelled or declined. You can try connecting again.")
        }
        let codes = url.queryItems?.filter { $0.name == "code" } ?? []
        guard codes.count == 1, let code = codes.first?.value, !code.isEmpty else {
            throw CSVError.invalid("The redirect URL does not contain an authorisation code.")
        }
        return code
    }
    func connect(_ provider: BankProvider, code input: String, expectedState: String?,
                 redirectURI: String = BankService.redirectURI, codeVerifier: String? = nil) async throws {
        let code = try Self.authorisationCode(input, redirectURI: redirectURI, expectedState: expectedState)
        var form = ["grant_type": "authorization_code", "code": code, "redirect_uri": redirectURI]
        if let codeVerifier { form["code_verifier"] = codeVerifier }
        let result = try await token(form)
        guard !result.access_token.isEmpty else { throw CSVError.invalid("TrueLayer returned an empty access token.") }
        let scopes = result.scope?.split(separator: " ").map(String.init) ?? provider.scopes
        try await validateOwnership(token: result.access_token, scopes: scopes, provider: provider)
        try save(Credential(accessToken: result.access_token, refreshToken: result.refresh_token,
            expiresAt: Date().addingTimeInterval(TimeInterval(max(0, result.expires_in - 60))), scopes: scopes), providerID: provider.id)
    }
    func useAccessToken(_ value: String, provider: BankProvider) async throws {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains(where: { $0.isWhitespace }) else { throw CSVError.invalid("Enter the access token only, without the Bearer prefix.") }
        try await validateOwnership(token: value, scopes: provider.scopes, provider: provider)
        try save(Credential(accessToken: value, expiresAt: nil, scopes: provider.scopes), providerID: provider.id)
    }
    func sync(_ provider: BankProvider) async throws -> BankSync {
        guard var credential = try credential(provider.id) else { throw CSVError.invalid("Connect this bank first.") }
        if let expiry = credential.expiresAt, expiry <= Date() {
            guard let refresh = credential.refreshToken else { throw CSVError.invalid("Access token expired. Authorise again or paste a new token.") }
            let result = try await token(["grant_type": "refresh_token", "refresh_token": refresh])
            credential.accessToken = result.access_token
            credential.refreshToken = result.refresh_token ?? refresh
            credential.expiresAt = Date().addingTimeInterval(TimeInterval(max(0, result.expires_in - 60)))
            if let scope = result.scope { credential.scopes = scope.split(separator: " ").map(String.init) }
            try save(credential, providerID: provider.id) // Save rotated tokens even if fetching fails.
        }
        let formatter = ISO8601DateFormatter()
        let end = Date()
        let start = Calendar(identifier: .gregorian).startOfDay(for: end.addingTimeInterval(-89 * 86400))
        let from = formatter.string(from: start), to = formatter.string(from: end)
        var windows: [BankSync.Window] = [], accounts: [BankAccount] = [], warnings: [String] = []
        var returned: [Account] = []
        let kinds = ["accounts", "cards"].filter { credential.scopes.contains($0) && provider.scopes.contains($0) }
        for kind in kinds {
            let listed: Results<Account> = try await request(dataURL.appendingPathComponent(kind), token: credential.accessToken)
            returned += listed.results
            // Only import accounts whose provider matches the selected source.
            for account in listed.results where provider.matchesAccountProviderID(account.provider?.provider_id) {
                let base = dataURL.appendingPathComponent(kind).appendingPathComponent(account.account_id)
                let balances: Results<Balance> = try await request(base.appendingPathComponent("balance"), token: credential.accessToken)
                var transactionsURL = URLComponents(url: base.appendingPathComponent("transactions"), resolvingAgainstBaseURL: false)!
                transactionsURL.queryItems = [URLQueryItem(name: "from", value: from), URLQueryItem(name: "to", value: to)]
                let transactions: Results<Transaction> = try await request(transactionsURL.url!, token: credential.accessToken)
                let prefix = "truelayer:\(provider.id):\(kind):\(account.account_id):"
                let name = (account.display_name ?? provider.name) + (account.partial_card_number.map { " · \($0)" } ?? "")
                func convert(_ rows: [Transaction], pending: Bool) throws -> [BankSync.Transaction] {
                    try rows.map { row in
                        let stable = row.normalised_provider_transaction_id.flatMap { $0.isEmpty ? nil : $0 }
                        guard !row.transaction_id.isEmpty, !row.amount.isNaN else { throw CSVError.invalid("A bank transaction is invalid. Nothing was imported.") }
                        let amount: Decimal
                        if row.transaction_type == "DEBIT" { amount = row.amount > 0 ? -row.amount : row.amount }
                        else if row.transaction_type == "CREDIT" { amount = row.amount < 0 ? -row.amount : row.amount }
                        else { throw CSVError.invalid("Unknown transaction direction. Nothing was imported.") }
                        if !pending && stable == nil && warnings.isEmpty {
                            warnings.append("Some transaction IDs can change. Date windows are reconciled; edits on indistinguishable transactions may need reviewing.")
                        }
                        return BankSync.Transaction(id: prefix + (pending ? "pending:" : "") + (stable != nil ? "stable:" : "request:") + (stable ?? row.transaction_id),
                            timestamp: row.timestamp, description: row.description ?? row.retailerName ?? "Bank transaction",
                            amount: NSDecimalNumber(decimal: amount).stringValue, currency: row.currency, account: name,
                            providerID: provider.id, merchantName: row.retailerName, classification: row.transaction_classification ?? [],
                            transactionCategory: row.transaction_category ?? "")
                    }
                }
                let entries = try convert(transactions.results, pending: false)
                let pendingEntries: [BankSync.Transaction]
                do {
                    // This endpoint returns the full pending snapshot, not the 90-day settled window.
                    let pending: Results<Transaction> = try await request(base.appendingPathComponent("transactions/pending"), token: credential.accessToken)
                    pendingEntries = try convert(pending.results, pending: true)
                } catch is PendingNotSupported {
                    pendingEntries = []
                } catch {
                    try Task.checkCancellation()
                    throw CSVError.invalid("Could not refresh pending transactions for \(name). Saved transactions were kept. \(error.localizedDescription)")
                }
                windows.append(BankSync.Window(prefix: prefix, from: from, to: to, entries: entries, pendingEntries: pendingEntries))
                accounts.append(BankAccount(id: prefix, name: name, kind: kind, currency: account.currency,
                    current: balances.results.first.map { NSDecimalNumber(decimal: $0.current).stringValue },
                    transactionCount: entries.filter { $0.amount != "0" }.count))
            }
        }
        guard !windows.isEmpty || !accounts.isEmpty else {
            throw accountSelectionError(provider: provider, kinds: kinds, returned: returned)
        }
        let sync = BankSync(providerID: provider.id, syncedAt: to, accounts: accounts, warnings: warnings, windows: windows)
        // Validate the full response before recording a successful sync.
        _ = try sync.merging(into: [], rules: [:])
        return sync
    }
    func recordSuccessfulSync(_ sync: BankSync) throws {
        guard var credential = try credential(sync.providerID) else {
            throw CSVError.invalid("Bank credentials could not be reopened after syncing.")
        }
        credential.accounts = sync.accounts
        credential.syncedAt = sync.syncedAt
        credential.categoryReport = sync.categoryReport
        try save(credential, providerID: sync.providerID)
    }

}
