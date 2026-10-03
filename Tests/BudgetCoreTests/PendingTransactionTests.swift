import Foundation
import XCTest
@testable import BudgetCore

final class PendingTransactionTests: XCTestCase {
    private let prefix = "truelayer:ob-test:accounts:one:"
    private func row(_ id: String, date: String = "2026-09-10T12:00:00Z", amount: String = "-20") -> BankSync.Transaction {
        BankSync.Transaction(id: prefix + id, timestamp: date, description: "Shop", amount: amount,
            currency: "GBP", account: "Test", providerID: "ob-test", merchantName: "Shop",
            classification: ["Shopping"], transactionCategory: "PURCHASE")
    }
    private func sync(_ booked: [BankSync.Transaction], pending: [BankSync.Transaction]?) -> BankSync {
        BankSync(providerID: "ob-test", syncedAt: "2026-09-17T12:00:00Z", accounts: [], warnings: [],
            windows: [.init(prefix: prefix, from: "2026-06-20T00:00:00Z", to: "2026-09-17T12:00:00Z", entries: booked, pendingEntries: pending)])
    }
    func testSettlementWithChangedIDDateAndAmountReplacesPendingWithoutDuplicates() throws {
        let first = try sync([], pending: [row("pending:request:old")]).merging(into: [], rules: [:])
        XCTAssertTrue(try XCTUnwrap(first.first).isPending)
        let settled = sync([row("stable:new", date: "2026-09-12T12:00:00Z", amount: "-22")], pending: [])
        let result = try settled.merging(into: first, rules: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isPending)
        XCTAssertEqual(result[0].amount, -22)
        XCTAssertEqual(try settled.merging(into: result, rules: [:]).count, 1)
    }
    func testPendingSnapshotReplacesChangedIDsKeepsIdenticalPurchasesAndRemovesCancellations() throws {
        let first = try sync([], pending: [row("pending:request:a"), row("pending:request:b")]).merging(into: [], rules: [:])
        let second = try sync([], pending: [row("pending:request:c"), row("pending:request:d")]).merging(into: first, rules: [:])
        XCTAssertEqual(second.count, 2)
        XCTAssertEqual(try sync([], pending: []).merging(into: second, rules: [:]).count, 0)
    }
    func testPendingOutsideSettledWindowAndUnfetchedAccountsArePreservedCorrectly() throws {
        let old = try row("stable:history", date: "2026-01-01T00:00:00Z").entry()
        var other = try row("pending:request:other").entry()
        other.id = "truelayer:ob-other:accounts:two:pending:request:other"; other.pending = true
        let result = try sync([], pending: [row("pending:request:old", date: "2026-05-30T00:00:00Z")]).merging(into: [old, other], rules: [:])
        XCTAssertEqual(result.count, 3)
        let preserved = try sync([], pending: nil).merging(into: result, rules: [:])
        XCTAssertEqual(preserved.count, 3)
        let cleared = try sync([], pending: []).merging(into: result, rules: [:])
        XCTAssertEqual(Set(cleared.map(\.id)), Set([old.id, other.id]))
    }
    func testStableIDInBothEndpointsIsOnlyCountedOnceAndInvalidPendingIsRejected() throws {
        let result = try sync([row("stable:same")], pending: [row("pending:stable:same")]).merging(into: [], rules: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertFalse(result[0].isPending)
        XCTAssertThrowsError(try sync([], pending: [row("pending:request:a"), row("pending:request:a")]).merging(into: [], rules: [:]))
        XCTAssertThrowsError(try sync([], pending: [row("stable:wrong-prefix")]).merging(into: [], rules: [:]))
    }
    func testPendingIncludedInTotalsButSeparatedForProgressAndNotTransferMatched() throws {
        let entries = try sync([row("stable:one", amount: "-60")], pending: [row("pending:request:two")]).merging(into: [], rules: [:])
        let month = try BankSync.date("2026-09-17T12:00:00Z")
        XCTAssertEqual(BudgetMath.spending(entries, currency: "GBP", month: month), 80)
        XCTAssertEqual(BudgetMath.spending(entries, currency: "GBP", month: month, includePending: false), 60)
        let progress = BudgetMath.progress(spent: 80, confirmed: 60, budget: 100)
        XCTAssertEqual(progress.confirmed, 0.6, accuracy: 0.00001)
        XCTAssertEqual(progress.pending, 0.2, accuracy: 0.00001)
        let over = BudgetMath.progress(spent: 150, confirmed: 100, budget: 100)
        XCTAssertEqual(over.confirmed + over.pending, 1, accuracy: 0.00001)
        XCTAssertGreaterThan(over.pending, 0)
        let refund = BudgetMath.progress(spent: 50, confirmed: 60, budget: 100)
        XCTAssertEqual(refund.pending, 0)
        let counterpart = Entry(id: "csv:other", date: entries[0].date, description: "Shop", amount: 20, account: "Other", category: .income)
        let pending = try XCTUnwrap(entries.first(where: \.isPending))
        XCTAssertFalse(TransferMatching.apply(to: [pending, counterpart]).contains { $0.category == .transfer })
        let legacy = try row("stable:legacy").entry()
        XCTAssertFalse(try JSONDecoder().decode(Entry.self, from: JSONEncoder().encode(legacy)).isPending)
    }

    func testPendingCategorySurvivesRefreshAndStableSettlement() throws {
        var entries = try sync([], pending: [row("pending:stable:one")]).merging(into: [], rules: [:])
        var rules: [String: BudgetCore.Category] = [:]
        entries = Categorisation.update(entries, transactionID: entries[0].id, category: .bills, allFromMerchant: false, rules: &rules)
        entries = try sync([], pending: [row("pending:stable:one")]).merging(into: entries, rules: rules)
        XCTAssertEqual(entries.first?.category, .bills)
        let settled = try sync([row("stable:one", date: "2026-09-12T12:00:00Z", amount: "-22")], pending: []).merging(into: entries, rules: rules)
        XCTAssertEqual(settled.first?.category, .bills)
        XCTAssertEqual(settled.first?.categoryOverride, .bills)
    }

    func testPendingCategoryFollowsOnlyUnambiguousChangedID() throws {
        var entries = try sync([], pending: [row("pending:request:old")]).merging(into: [], rules: [:])
        entries[0].categoryOverride = .bills
        let refreshed = try sync([], pending: [row("pending:request:new")]).merging(into: entries, rules: [:])
        XCTAssertEqual(refreshed.first?.category, .bills)
        let settled = try sync([row("stable:new")], pending: []).merging(into: refreshed, rules: [:])
        XCTAssertEqual(settled.first?.category, .bills)
        let ambiguous = try sync([row("stable:a"), row("stable:b")], pending: []).merging(into: entries, rules: [:])
        XCTAssertTrue(ambiguous.allSatisfy { $0.categoryOverride == nil })
    }

    func testMerchantCategoryRuleFromPendingAppliesAfterChangedSettlement() throws {
        var entries = try sync([], pending: [row("pending:request:old")]).merging(into: [], rules: [:])
        var rules: [String: BudgetCore.Category] = [:]
        entries = Categorisation.update(entries, transactionID: entries[0].id, category: .bills, allFromMerchant: true, rules: &rules)
        let settled = try sync([row("stable:new", date: "2026-09-12T12:00:00Z", amount: "-22")], pending: []).merging(into: entries, rules: rules)
        XCTAssertEqual(settled.first?.category, .bills)
    }
}
