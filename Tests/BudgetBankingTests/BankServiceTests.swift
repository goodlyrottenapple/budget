import Foundation
import CryptoKit
import XCTest
import BudgetCore
@testable import BudgetBanking

/// A real local HTTP server exercises Foundation's URL cache, which URLProtocol
/// mocks don't reliably reproduce. Only fake tokens and in-memory secrets are used.
private final class BankServer {
    let process = Process()
    let baseURL: URL
    init() throws {
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-u", Bundle.module.url(forResource: "bank_http_server", withExtension: "py", subdirectory: "Fixtures")!.path]
        process.standardOutput = pipe
        try process.run()
        var data = Data()
        while let byte = try pipe.fileHandleForReading.read(upToCount: 1), !byte.isEmpty {
            if byte == Data([10]) { break }
            data.append(byte)
        }
        guard let port = Int(String(decoding: data, as: UTF8.self)) else {
            process.terminate()
            throw NSError(domain: "BankServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Local bank test server failed to start"])
        }
        baseURL = URL(string: "http://127.0.0.1:\(port)")!
    }
    deinit {
        if process.isRunning { process.terminate(); process.waitUntilExit() }
    }
}

@MainActor
final class BankServiceTests: XCTestCase {
    private final class Secrets {
        var values: [String: Data] = ["client-secret": Data("fake-client-secret".utf8)]
    }
    private func service(_ server: BankServer, _ secrets: Secrets) -> BankService {
        BankService(dataURL: server.baseURL.appendingPathComponent("data/v1"),
                    tokenURL: server.baseURL.appendingPathComponent("connect/token"),
                    readSecret: { secrets.values[$0] },
                    writeSecret: { secrets.values[$1] = $0 },
                    removeSecret: { secrets.values.removeValue(forKey: $0) })
    }
    private func provider(_ id: String) throws -> BankProvider {
        let data = try JSONSerialization.data(withJSONObject: ["provider_id": id, "display_name": id,
            "country": "uk", "scopes": id == "ob-amex" ? ["cards", "balance", "transactions", "offline_access"]
                : ["accounts", "cards", "balance", "transactions", "offline_access"]])
        return try JSONDecoder().decode(BankProvider.self, from: data)
    }

    func testSharedClientSecretCanBeViewedAndReplacedWithoutChangingBankTokens() throws {
        let secrets = Secrets()
        let bankToken = Data("saved-bank-credential".utf8)
        secrets.values["ob-natwest"] = bankToken
        let service = BankService(readSecret: { secrets.values[$0] },
                                  writeSecret: { secrets.values[$1] = $0 },
                                  removeSecret: { secrets.values.removeValue(forKey: $0) })
        XCTAssertEqual(try service.savedClientSecret(), "fake-client-secret")
        try service.saveClientSecret("  replacement-shared-secret  ")
        XCTAssertEqual(try service.savedClientSecret(), "replacement-shared-secret")
        XCTAssertEqual(secrets.values["ob-natwest"], bankToken)
        // Opening the screen before setup must not create a credential.
        secrets.values.removeValue(forKey: "client-secret")
        XCTAssertEqual(try service.savedClientSecret(), "")
        XCTAssertFalse(service.hasClientSecret)
        secrets.values["client-secret"] = Data([0xff])
        XCTAssertThrowsError(try service.savedClientSecret())
    }
    private func connect(_ bank: BankProvider, to service: BankService) async throws {
        let state = UUID().uuidString
        var url = URLComponents(string: BankService.redirectURI)!
        url.queryItems = [URLQueryItem(name: "code", value: bank.id), URLQueryItem(name: "state", value: state)]
        try await service.connect(bank, code: url.url!.absoluteString, expectedState: state)
    }

    func testCallbackRejectsWrongHostPathStateAndAmbiguousParameters() throws {
        let redirect = "https://budget.example/truelayer/callback"
        XCTAssertEqual(try BankService.authorisationCode(redirect + "?state=expected&code=test-code",
                                                         redirectURI: redirect, expectedState: "expected"), "test-code")
        let invalid = [
            "com.personal.budgetr.auth://other/callback?state=expected&code=x",
            "com.personal.budgetr.auth://truelayer/other?state=expected&code=x",
            "com.personal.budgetr.auth://truelayer/callback?state=wrong&code=x",
            "com.personal.budgetr.auth://user@truelayer/callback?state=expected&code=x",
            "https://other.example/truelayer/callback?state=expected&code=x",
            "http://budget.example/truelayer/callback?state=expected&code=x",
            "https://budget.example:8443/truelayer/callback?state=expected&code=x",
            "https://user@budget.example/truelayer/callback?state=expected&code=x",
            "https://budget.example/other?state=expected&code=x",
            redirect + "?state=wrong&code=x", redirect + "?code=x",
            redirect + "?state=expected&state=other&code=x",
            redirect + "?state=expected&code=x&code=y",
            redirect + "?state=expected&code=", redirect + "?state=expected&code=x#fragment",
            redirect + "?state=expected&error=access_denied"
        ]
        for input in invalid {
            XCTAssertThrowsError(try BankService.authorisationCode(input, redirectURI: redirect, expectedState: "expected"))
        }
        XCTAssertEqual(try BankService.authorisationCode("com.personal.budgetr.auth://truelayer/callback?state=expected&code=x",
                                                         redirectURI: redirect, expectedState: "expected"), "x")
    }

    func testAutomaticCallbackSurvivesRelaunchAndCannotBeReplayed() async throws {
        let server = try BankServer(), secrets = Secrets()
        let service = service(server, secrets), bank = try provider("ob-callback-test")
        let redirect = "https://budget.example/truelayer/callback"
        let auth = try service.beginAuthorisation(bank, redirectURI: redirect)
        let state = try XCTUnwrap(URLComponents(url: auth, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        let verifier = try XCTUnwrap(service.pendingAuthorisation()?.codeVerifier)
        XCTAssertEqual(verifier.count, 43)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let parameters = URLComponents(url: auth, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(parameters.first { $0.name == "code_challenge" }?.value, challenge)
        XCTAssertEqual(parameters.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertNil(parameters.first { $0.name == "code_verifier" })
        XCTAssertEqual(try service.pendingAuthorisation()?.provider.id, bank.id)
        let relaunched = self.service(server, secrets)
        let wrong = URL(string: redirect + "?state=wrong&code=ob-callback-test")!
        do { _ = try await relaunched.completeAuthorisation(wrong); XCTFail("Accepted wrong state") } catch {}
        XCTAssertNotNil(try relaunched.pendingAuthorisation())
        let callback = URL(string: "com.personal.budgetr.auth://truelayer/callback?state=\(state)&code=ob-callback-test")!
        let connected = try await relaunched.completeAuthorisation(callback)
        XCTAssertEqual(connected.id, bank.id)
        XCTAssertNotNil(try relaunched.credential(bank.id)?.refreshToken)
        XCTAssertNil(try relaunched.pendingAuthorisation())
        do { _ = try await relaunched.completeAuthorisation(callback); XCTFail("Accepted replay") } catch {}
    }

    func testExpiredAndDeclinedCallbacksDoNotReplaceCredentials() async throws {
        let server = try BankServer(), secrets = Secrets()
        let service = service(server, secrets), bank = try provider("ob-natwest")
        try await connect(bank, to: service)
        let original = secrets.values[bank.id]
        let redirect = "https://budget.example/truelayer/callback"
        let started = Date(timeIntervalSince1970: 10000)
        _ = try service.beginAuthorisation(bank, redirectURI: redirect, now: started)
        var state = try XCTUnwrap(service.pendingAuthorisation()?.state)
        do {
            _ = try await service.completeAuthorisation(URL(string: redirect + "?state=\(state)&code=ob-natwest")!, now: started.addingTimeInterval(1201))
            XCTFail("Accepted expired flow")
        } catch {}
        XCTAssertNil(try service.pendingAuthorisation())
        _ = try service.beginAuthorisation(bank, redirectURI: redirect)
        state = try XCTUnwrap(service.pendingAuthorisation()?.state)
        do {
            _ = try await service.completeAuthorisation(URL(string: redirect + "?state=\(state)&error=access_denied")!)
            XCTFail("Accepted declined flow")
        } catch {}
        XCTAssertNil(try service.pendingAuthorisation())
        XCTAssertEqual(secrets.values[bank.id], original)
    }

    func testSequentialAuthorisationsAndSyncsStayWithTheirOwnBanks() async throws {
        let server = try BankServer(), secrets = Secrets()
        let service = service(server, secrets)
        let ids = ["ob-natwest", "ob-lloyds", "ob-revolut", "ob-amex", "ob-barclays"]
        for id in ids {
            try await connect(provider(id), to: service)
            // Allow time for the old configuration's asynchronous cache writes.
            try await Task.sleep(for: .milliseconds(100))
        }
        for id in ids.reversed() {
            let result = try await service.sync(provider(id))
            XCTAssertEqual(result.accounts.count, 1)
            XCTAssertEqual(result.accounts.first?.name, id)
            XCTAssertEqual(result.windows.first?.entries.first?.providerID, id)
            let pending = try XCTUnwrap(result.windows.first?.pendingEntries)
            XCTAssertEqual(pending.count, 1)
            XCTAssertEqual(pending.first?.amount, "-3")
            XCTAssertTrue(try result.merging(into: [], rules: [:]).contains(where: \.isPending))
            try service.recordSuccessfulSync(result)
            XCTAssertEqual(try service.credential(id)?.accessToken, "test-\(id)-v1")
        }
    }

    func testUnsupportedPendingStillSyncsSettledButTransientFailureRejectsSnapshot() async throws {
        let server = try BankServer(), secrets = Secrets()
        let service = service(server, secrets)
        let unsupported = try provider("ob-pending-unsupported")
        try await connect(unsupported, to: service)
        let result = try await service.sync(unsupported)
        XCTAssertEqual(result.windows.first?.pendingEntries?.count, 0)
        XCTAssertEqual(result.windows.first?.entries.count, 1)
        let failing = try provider("ob-pending-error")
        try await connect(failing, to: service)
        do {
            _ = try await service.sync(failing)
            XCTFail("A failed pending fetch must not clear the saved snapshot")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Could not refresh pending transactions"))
        }
    }

    func testRefreshRotatesOnlyTheSelectedBanksTokensAndPreservesMetadata() async throws {
        let server = try BankServer(), secrets = Secrets()
        let service = service(server, secrets)
        for id in ["ob-natwest", "ob-revolut"] {
            let bank = try provider(id)
            var credential = BankService.Credential(accessToken: "test-\(id)-v1",
                refreshToken: "refresh-\(id)-v1", expiresAt: Date(timeIntervalSince1970: 0), scopes: bank.scopes)
            credential.syncedAt = "2026-09-15T12:00:00Z"
            secrets.values[id] = try JSONEncoder().encode(credential)
        }
        let revolutBefore = secrets.values["ob-revolut"]
        let natwest = try await service.sync(provider("ob-natwest"))
        XCTAssertEqual(natwest.accounts.first?.name, "ob-natwest")
        let updated = try XCTUnwrap(service.credential("ob-natwest"))
        XCTAssertEqual(updated.accessToken, "test-ob-natwest-v2")
        XCTAssertEqual(updated.refreshToken, "refresh-ob-natwest-v2")
        XCTAssertGreaterThan(try XCTUnwrap(updated.expiresAt), Date())
        XCTAssertEqual(updated.syncedAt, "2026-09-15T12:00:00Z")
        XCTAssertEqual(secrets.values["ob-revolut"], revolutBefore)
        let revolut = try await service.sync(provider("ob-revolut"))
        XCTAssertEqual(revolut.accounts.first?.name, "ob-revolut")
        XCTAssertEqual(try service.credential("ob-revolut")?.refreshToken, "refresh-ob-revolut-v2")
    }

    func testEmptyAndMissingProviderResponsesDoNotClaimWrongBankOrOverwriteCredentials() async throws {
        let server = try BankServer(), secrets = Secrets()
        let service = service(server, secrets)
        let bank = try provider("ob-natwest")
        try await connect(bank, to: service)
        let saved = secrets.values[bank.id]
        for token in ["test-empty", "test-missing-provider"] {
            do {
                try await service.useAccessToken(token, provider: bank)
                XCTFail("Expected an unusable account list")
            } catch {
                XCTAssertFalse(error is BankService.WrongBankToken)
            }
            XCTAssertEqual(secrets.values[bank.id], saved)
            var credential = try XCTUnwrap(service.credential(bank.id))
            credential.accessToken = token
            secrets.values[bank.id] = try JSONEncoder().encode(credential)
            do {
                _ = try await service.sync(bank)
                XCTFail("Expected an unusable account list")
            } catch {
                XCTAssertFalse(error is BankService.WrongBankToken)
            }
            secrets.values[bank.id] = saved
        }
    }

    func testRealProviderMismatchRejectsTokenWithoutOverwritingSavedConnection() async throws {
        let server = try BankServer(), secrets = Secrets()
        let service = service(server, secrets)
        let bank = try provider("ob-natwest")
        try await connect(bank, to: service)
        let saved = secrets.values[bank.id]
        do {
            try await service.useAccessToken("test-ob-revolut-v1", provider: bank)
            XCTFail("Expected bank mismatch")
        } catch {
            XCTAssertTrue(error is BankService.WrongBankToken)
        }
        XCTAssertEqual(secrets.values[bank.id], saved)
        let result = try await service.sync(bank)
        XCTAssertEqual(result.accounts.first?.name, bank.id)
    }
}
