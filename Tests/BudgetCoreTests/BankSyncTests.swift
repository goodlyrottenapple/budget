import Foundation
import XCTest
@testable import BudgetCore

final class BankSyncTests: XCTestCase {
    private let prefix = "truelayer:ob-amex:cards:card-1:"
    private func row(_ id: String = "stable:1", date: String = "2026-09-10T12:00:00Z", amount: String = "-12.34") -> BankSync.Transaction {
        BankSync.Transaction(id: prefix + id, timestamp: date, description: "SHOP", amount: amount,
            currency: "GBP", account: "Amex · 1234", providerID: "ob-amex", merchantName: "Shop",
            classification: ["Shopping"], transactionCategory: "PURCHASE")
    }
    private func sync(_ rows: [BankSync.Transaction]) -> BankSync {
        BankSync(providerID: "ob-amex", syncedAt: "2026-09-15T12:00:00Z", accounts: [], warnings: [],
            windows: [BankSync.Window(prefix: prefix, from: "2026-06-17T00:00:00Z", to: "2026-09-15T12:00:00Z", entries: rows)])
    }
    func testRepeatedSyncUpdatesAmountsAndPreservesNotesAndSingleCategory() throws {
        var old = try row().entry()
        old.notes = "Workshop supplies"; old.categoryOverride = .house; old.category = .house
        old.reimbursement = Decimal(string: "10.12")
        old.recurringMonthly = true
        let result = try sync([row(amount: "-15.12")]).merging(into: [old], rules: ["shop": .house])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].amount, Decimal(string: "-15.12"))
        XCTAssertEqual(result[0].notes, old.notes)
        XCTAssertEqual(result[0].reimbursement, old.reimbursement)
        XCTAssertEqual(result[0].recurringMonthly, true)
        XCTAssertEqual(result[0].category, .house)
        XCTAssertEqual(try sync([row(amount: "-15.12")]).merging(into: result, rules: [:]).count, 1)
    }
    func testChangedRequestIDsReplaceWindowAndKeepUnambiguousEdits() throws {
        var old = try row("request:old").entry()
        old.notes = "Keep me"; old.categoryOverride = .house; old.category = .house
        old.reimbursement = 5
        old.recurringMonthly = true
        let result = try sync([row("request:new")]).merging(into: [old], rules: [:])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].id, prefix + "request:new")
        XCTAssertEqual(result[0].notes, "Keep me")
        XCTAssertEqual(result[0].reimbursement, 5)
        XCTAssertEqual(result[0].recurringMonthly, true)
        XCTAssertEqual(result[0].category, .house)
    }
    func testIdenticalPurchasesAreNotCollapsedAndEditsAreNotGuessed() throws {
        var old = try row("request:old").entry(); old.notes = "Only one of these"
        let result = try sync([row("request:new1"), row("request:new2")]).merging(into: [old], rules: [:])
        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.notes == nil })
    }
    func testEmptySuccessfulWindowKeepsOlderHistoryAndOtherSources() throws {
        let old = try row("stable:older", date: "2026-05-01T12:00:00Z").entry()
        let recent = try row().entry()
        let csv = Entry(id: "yonder:1", date: recent.date, description: "Shop", amount: -5, account: "Yonder")
        let result = try sync([]).merging(into: [old, recent, csv], rules: [:])
        XCTAssertEqual(Set(result.map(\.id)), Set([old.id, recent.id, csv.id]))
    }
    func testOmittedBookedStablePaymentIsRetainedAndUpdatedWhenItReturns() throws {
        var booked = try row("stable:natwest-payment", amount: "-36").entry()
        booked.description = "28AUG A/C 12345678"
        booked.notes = "Keep this"
        let omitted = try sync([]).merging(into: [booked], rules: [:])
        XCTAssertEqual(omitted.count, 1)
        XCTAssertEqual(omitted.first?.amount, -36)
        XCTAssertFalse(try XCTUnwrap(omitted.first).isPending)
        let returned = try sync([row("stable:natwest-payment", amount: "-36")]).merging(into: omitted, rules: [:])
        XCTAssertEqual(returned.count, 1)
        XCTAssertEqual(returned.first?.notes, "Keep this")
        XCTAssertEqual(returned.first?.amount, -36)
    }
    func testUnstableRequestIDsStillReplaceTheirWindow() throws {
        let previous = try row("request:temporary").entry()
        XCTAssertTrue(try sync([]).merging(into: [previous], rules: [:]).isEmpty)
    }
    func testDiagnosticSeparatesReturnedAndSavedPaymentsWithoutExposingIDs() throws {
        let booked = row("stable:private-id", amount: "-36")
        let saved = try booked.entry()
        let result = BankSync(providerID: "ob-amex", syncedAt: "2026-09-19T12:00:00Z", accounts: [], warnings: [],
            windows: [.init(prefix: prefix, from: "2026-06-20T00:00:00Z", to: "2026-09-19T12:00:00Z", entries: [], pendingEntries: [row("pending:request:private", amount: "-36")])])
        let report = result.transactionReport(query: "£36.00", saved: [saved])
        XCTAssertTrue(report.contains("Settled response: 0 returned, 0 matches"))
        XCTAssertTrue(report.contains("Pending response: 1 returned, 1 matches"))
        XCTAssertTrue(report.contains("Saved in Budget: 1 matches"))
        XCTAssertFalse(report.contains("private"))
        XCTAssertFalse(report.contains(prefix))
        XCTAssertTrue(result.transactionReport(query: "shop", saved: []).contains("Pending response: 1 returned, 1 matches"))
    }
    func testMalformedOrDuplicateWindowRejectsWholeSync() throws {
        let original = try row().entry()
        XCTAssertThrowsError(try sync([row(), row()]).merging(into: [original], rules: [:]))
        XCTAssertThrowsError(try sync([row(date: "2026-01-01T00:00:00Z")]).merging(into: [original], rules: [:]))
        XCTAssertThrowsError(try sync([row(amount: "invalid")]).merging(into: [original], rules: [:]))
        XCTAssertEqual(original.amount, Decimal(string: "-12.34"))
    }
    func testAutomaticSyncUsesSixHourBoundaryAndSkipsRecentSuccesses() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertFalse(BankSyncSchedule.isDue(lastSuccess: now.addingTimeInterval(-21_599), lastAutomaticAttempt: nil, now: now))
        XCTAssertTrue(BankSyncSchedule.isDue(lastSuccess: now.addingTimeInterval(-21_600), lastAutomaticAttempt: nil, now: now))
        XCTAssertTrue(BankSyncSchedule.isDue(lastSuccess: nil, lastAutomaticAttempt: nil, now: now))
    }
    func testFailedAutomaticAttemptsHaveCooldownWithoutBlockingLaterRetry() {
        let now = Date(timeIntervalSince1970: 100_000)
        XCTAssertFalse(BankSyncSchedule.isDue(lastSuccess: nil, lastAutomaticAttempt: now.addingTimeInterval(-899), now: now))
        XCTAssertTrue(BankSyncSchedule.isDue(lastSuccess: nil, lastAutomaticAttempt: now.addingTimeInterval(-900), now: now))
        XCTAssertFalse(BankSyncSchedule.isDue(lastSuccess: now, lastAutomaticAttempt: now.addingTimeInterval(-901), now: now))
    }
    func testCategoryReportShowsOnlyLabelsAndCountsAndHidesZeros() {
        let report = sync([row(), row("stable:2"), row("stable:zero", amount: "0")]).categoryReport
        XCTAssertTrue(report.contains("Non-zero transactions: 2"))
        XCTAssertTrue(report.contains("With spending classifications: 2"))
        XCTAssertTrue(report.contains("Shopping: 2"))
        XCTAssertTrue(report.contains("PURCHASE: 2"))
        XCTAssertFalse(report.contains("SHOP"))
        XCTAssertFalse(report.contains("1234"))
        XCTAssertFalse(report.contains(prefix))
        XCTAssertFalse(report.contains("12.34"))
    }
    func testNewArrivalsApplyMerchantRulesAndParseProviderDates() throws {
        let result = try sync([row(date: "2026-09-10T12:00:00.123456Z")]).merging(into: [], rules: ["shop": .house])
        XCTAssertEqual(result[0].category, .house)
        XCTAssertEqual(result[0].providerID, "ob-amex")
        XCTAssertEqual(try BankSync.date("2026-09-10T12:00:00"), try BankSync.date("2026-09-10T12:00:00Z"))
    }
}
