import Foundation
import SwiftData
import XCTest
import BudgetCore
@testable import BudgetPersistence

@MainActor
final class BudgetPersistenceTests: XCTestCase {
    func testAccountContinuationsSurviveReopeningAndCanBeUnlinked() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Budget.store")
        let old = "truelayer:bank:cards:old:"
        let new = "truelayer:bank:cards:new:"
        let entry = Entry(id: old + "stable:one", date: Date(), description: "Purchase", amount: -36, account: "Old card")
        var repository: BudgetRepository? = try BudgetRepository(storeURL: url)
        try repository?.save(BudgetSnapshot(entries: [entry], budgets: [:], isDemo: false,
                                           accountContinuations: [old: new]))
        repository = nil
        let reopened = try BudgetRepository(storeURL: url)
        var state = try XCTUnwrap(reopened.load())
        XCTAssertEqual(state.accountContinuations, [old: new])
        XCTAssertEqual(state.entries.first?.id, entry.id)
        XCTAssertEqual(state.entries.first?.account, "Old card")
        state.accountContinuations = [:]
        try reopened.save(state)
        XCTAssertEqual(try reopened.load()?.accountContinuations, [:])
    }

    func testDeletedTransactionsSurviveReopeningAndBlockReimport() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Budget.store")
        let deleted = Entry(id: "truelayer:bank:cards:old:stable:one", date: Date(),
                            description: "Incorrect payment", amount: -36, account: "Card")
        let kept = Entry(id: "truelayer:bank:cards:new:stable:two", date: Date(),
                         description: "Correct payment", amount: -36, account: "Card")
        var repository: BudgetRepository? = try BudgetRepository(storeURL: url)
        try repository?.save(BudgetSnapshot(entries: [kept], budgets: [:], isDemo: false,
                                           deletedTransactions: [deleted]))
        repository = nil
        let reopened = try BudgetRepository(storeURL: url)
        let state = try XCTUnwrap(reopened.load())
        XCTAssertEqual(state.entries.map(\.id), [kept.id])
        XCTAssertEqual(state.deletedTransactions.map(\.id), [deleted.id])
        XCTAssertEqual(TransactionExclusions.applying(state.deletedTransactions, to: [deleted, kept]).map(\.id), [kept.id])
    }

    func testBudgetCurrencySurvivesReopeningAndLegacyDefaultIsUnset() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Budget.store")
        var repository: BudgetRepository? = try BudgetRepository(storeURL: url)
        var snapshot = BudgetSnapshot(entries: [], budgets: ["Dining": 200], isDemo: false)
        try repository?.save(snapshot)
        XCTAssertNil(try repository?.load()?.budgetCurrency)
        snapshot.budgetCurrency = "EUR"
        try repository?.save(snapshot)
        repository = nil
        let reopened = try BudgetRepository(storeURL: url)
        XCTAssertEqual(try reopened.load()?.budgetCurrency, "EUR")
        XCTAssertEqual(try reopened.load()?.budgets["Dining"], 200)
    }

    func testReimbursementSurvivesReopeningAndCanBeCleared() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Budget.store")
        var entry = Entry(id: "expense", date: Date(), description: "Work trip", amount: -100, account: "Yonder", category: .travel)
        entry.reimbursement = Decimal(string: "45.67")
        entry.pending = true
        entry.recurringMonthly = true
        var repository: BudgetRepository? = try BudgetRepository(storeURL: url)
        try repository?.save(BudgetSnapshot(entries: [entry], budgets: [:], isDemo: false))
        repository = nil
        let reopened = try BudgetRepository(storeURL: url)
        var state = try XCTUnwrap(reopened.load())
        XCTAssertEqual(state.entries.first?.reimbursement, Decimal(string: "45.67"))
        XCTAssertEqual(state.entries.first?.amount, -100)
        XCTAssertTrue(try XCTUnwrap(state.entries.first).isPending)
        XCTAssertEqual(state.entries.first?.recurringMonthly, true)
        state.entries[0].reimbursement = nil
        state.entries[0].pending = nil
        state.entries[0].recurringMonthly = nil
        try reopened.save(state)
        XCTAssertNil(try reopened.load()?.entries.first?.reimbursement)
        XCTAssertFalse(try XCTUnwrap(reopened.load()?.entries.first).isPending)
        XCTAssertNil(try reopened.load()?.entries.first?.recurringMonthly)
    }

    func testCustomNameAndIconSurviveReopeningAndAreRemovedWithOverride() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Budget.store")
        let icon = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a9WQAAAAASUVORK5CYII=")!
        let retailer = Retailer(name: "Neighbourhood café", domain: nil, logo_url: nil, customIconData: icon)
        let entry = Entry(id: "one", date: Date(), description: "LOCAL CAFE", amount: -5, account: "Yonder")
        var first: BudgetRepository? = try BudgetRepository(storeURL: url)
        var match = MerchantMatch(retailer: retailer, isOverride: true)
        match.matchingPattern = "LOCAL.*CAFE"
        try first?.save(BudgetSnapshot(entries: [entry], budgets: [:], isDemo: false,
            merchantMatches: [entry.merchantKey: match]))
        first = nil
        let reopened = try BudgetRepository(storeURL: url)
        XCTAssertEqual(try reopened.load()?.merchantMatches[entry.merchantKey]?.matchingPattern, "LOCAL.*CAFE")
        var state = try XCTUnwrap(reopened.load())
        XCTAssertEqual(state.merchantMatches[entry.merchantKey]?.retailer, retailer)
        XCTAssertEqual(state.entries.first?.description, entry.description)
        state.merchantMatches[entry.merchantKey] = MerchantMatch(retailer: nil, isOverride: true)
        try reopened.save(state)
        XCTAssertNil(try reopened.load()?.merchantMatches[entry.merchantKey]?.retailer)
        let records = try ModelContext(reopened.container).fetch(FetchDescriptor<BudgetModels.RetailerMatch>())
        XCTAssertEqual(records.count, 1)
        XCTAssertNil(try JSONDecoder().decode(MerchantMatch.self, from: records[0].metadata).retailer)
    }

    private func directory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func testSearchCacheAndRetailerOverridesSurviveReopeningAndSnapshotSaves() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Budget.store")
        let retailer = Retailer(name: "Shop", domain: "shop.com", logo_url: "https://img.logo.dev/shop.com?token=pk_example")
        var first: BudgetRepository? = try BudgetRepository(storeURL: url)
        XCTAssertNil(try first?.cachedRetailers(for: "Shop"))
        try first?.cacheRetailers([retailer], for: "Shop")
        try first?.cacheRetailers([], for: "Unknown")
        try first?.cacheRetailers([retailer], for: " SHOP ")
        let snapshot = BudgetSnapshot(entries: [], budgets: [:], isDemo: false,
            merchantMatches: ["original shop": MerchantMatch(retailer: retailer, isOverride: true),
                              "local shop": MerchantMatch(retailer: nil, isOverride: true)])
        try first?.save(snapshot)
        first = nil
        let reopened = try BudgetRepository(storeURL: url)
        XCTAssertEqual(try reopened.cachedRetailers(for: " shop "), [retailer])
        XCTAssertEqual(try reopened.cachedRetailers(for: "unknown"), [])
        XCTAssertNil(try reopened.cachedRetailers(for: "new retailer"))
        XCTAssertEqual(try reopened.load()?.merchantMatches["original shop"]?.retailer, retailer)
        XCTAssertEqual(try reopened.load()?.merchantMatches["original shop"]?.isOverride, true)
        XCTAssertEqual(try reopened.load()?.merchantMatches["local shop"]?.isOverride, true)
        XCTAssertNil(try reopened.load()?.merchantMatches["local shop"]?.retailer)
        let context = ModelContext(reopened.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BudgetModels.RetailerSearch>()), 2)
        try reopened.save(snapshot)
        XCTAssertEqual(try reopened.cachedRetailers(for: "Shop"), [retailer])
    }

    func testRecordsRetainCategoriesRulesBudgetsAndSources() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let providerJSON = #"{"provider_id":"ob-revolut","display_name":"Revolut","country":"uk","logo_url":"https://providers-assets.truelayer.com/ob-revolut/logo.svg","scopes":["accounts","transactions"]}"#
        let provider = try JSONDecoder().decode(BankProvider.self, from: Data(providerJSON.utf8))
        var entry = Entry(id: "yonder:one", date: Date(), description: "Shop", amount: Decimal(string: "-12.34")!, account: "Yonder", category: .house)
        entry.categoryOverride = .house
        let snapshot = BudgetSnapshot(entries: [entry], budgets: ["Travel": 120, "House": 250], isDemo: false,
                                      sources: [provider], merchantRules: ["shop": .house])
        let repository = try BudgetRepository(storeURL: directory.appendingPathComponent("Budget.store"))
        try repository.save(snapshot)
        let loaded = try XCTUnwrap(repository.load())
        XCTAssertEqual(loaded.entries[0].id, entry.id)
        XCTAssertEqual(loaded.entries[0].amount, entry.amount)
        XCTAssertEqual(loaded.entries[0].categoryOverride, .house)
        XCTAssertEqual(loaded.budgets["Travel"], 120)
        XCTAssertNil(loaded.budgets["Transport"])
        XCTAssertEqual(loaded.merchantRules["shop"], .house)
        XCTAssertEqual(loaded.sources.first?.id, provider.id)
        XCTAssertFalse(loaded.isDemo)
    }

    func testReopeningStoreKeepsEdits() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = directory.appendingPathComponent("Budget.store")
        let entry = Entry(id: "one", date: Date(), description: "Shop", amount: -5, account: "Yonder")
        var first: BudgetRepository? = try BudgetRepository(storeURL: store)
        try first?.save(BudgetSnapshot(entries: [entry], budgets: [:], isDemo: false))
        var snapshot = try XCTUnwrap(first?.load())
        snapshot.entries[0].category = .entertainment
        snapshot.entries[0].categoryOverride = .entertainment
        snapshot.entries[0].notes = "Birthday present"
        snapshot.merchantRules = ["shop": .shopping]
        try first?.save(snapshot)
        first = nil
        let reopened = try BudgetRepository(storeURL: store)
        let loaded = try XCTUnwrap(reopened.load())
        XCTAssertEqual(loaded.entries.count, 1)
        XCTAssertEqual(loaded.entries[0].categoryOverride, .entertainment)
        XCTAssertEqual(loaded.entries[0].notes, "Birthday present")
        XCTAssertEqual(loaded.merchantRules["shop"], .shopping)
    }

    func testRepeatedSavesUpsertAndRemovingRulesPersists() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try BudgetRepository(storeURL: directory.appendingPathComponent("Budget.store"))
        let entry = Entry(id: "one", date: Date(), description: "Shop", amount: -5, account: "Yonder")
        var snapshot = BudgetSnapshot(entries: [entry], budgets: ["House": 50], isDemo: false, merchantRules: ["shop": .house])
        for _ in 0..<3 { try repository.save(snapshot) }
        XCTAssertEqual(try repository.load()?.entries.count, 1)
        snapshot.merchantRules = [:]
        snapshot.budgets = ["House": 100]
        try repository.save(snapshot)
        XCTAssertEqual(try repository.load()?.budgets["House"], 100)
        XCTAssertTrue(try repository.load()?.merchantRules.isEmpty == true)
        let context = ModelContext(repository.container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<BudgetModels.Transaction>()), 1)
    }

    func testDuplicateIDsAreRejectedWithoutChangingExistingData() throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = try BudgetRepository(storeURL: directory.appendingPathComponent("Budget.store"))
        let entry = Entry(id: "one", date: Date(), description: "Shop", amount: -5, account: "Yonder")
        let original = BudgetSnapshot(entries: [entry], budgets: [:], isDemo: false)
        try repository.save(original)
        var bad = original; bad.entries.append(entry)
        XCTAssertThrowsError(try repository.save(bad))
        XCTAssertEqual(try repository.load()?.entries.count, 1)
    }
}
