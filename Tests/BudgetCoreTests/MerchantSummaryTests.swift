import Foundation
import XCTest
@testable import BudgetCore

final class MerchantSummaryTests: XCTestCase {
    func testDisplayedNameNormalisationCombinesAccountsDatesAndPending() {
        var first = Entry(id: "1", date: Date(timeIntervalSince1970: 0), description: "RAW SHOP A", amount: -100, account: "Bank")
        first.reimbursement = 20
        var pending = Entry(id: "2", date: Date(), description: "RAW SHOP B", amount: -40, account: "Card")
        pending.pending = true
        let refund = Entry(id: "3", date: Date(), description: "REFUND", amount: 10, account: "Other")
        let unrelated = Entry(id: "4", date: Date(), description: "Other shop", amount: -200, account: "Bank")
        let zero = Entry(id: "5", date: Date(), description: "Shop", amount: 0, account: "Bank")
        let names = ["1": "Shop Name", "2": " shop\tNAME\n", "3": "SHOP\u{00A0}NAME", "4": "Different shop", "5": "ShopName"]
        let summary = MerchantSummary(entries: [first, pending, refund, unrelated, zero], merchantName: "shopname", displayName: { names[$0.id]! })
        XCTAssertEqual(summary.transactionCount, 3)
        XCTAssertEqual(summary.currencies.count, 1)
        XCTAssertEqual(summary.currencies[0].totalSpend, 110)
        XCTAssertEqual(summary.currencies[0].averageTransaction, Decimal(110) / 3)
    }

    func testCurrenciesStaySeparateAndEmptyNamesDoNotGroupUnrelatedTransactions() {
        let entries = [Entry(id: "1", date: Date(), description: "Shop", amount: -10, currency: "GBP", account: "Bank"),
                       Entry(id: "2", date: Date(), description: "Shop", amount: -30, currency: "EUR", account: "Card")]
        let summary = MerchantSummary(entries: entries, merchantName: "Shop", displayName: { $0.description })
        XCTAssertEqual(summary.transactionCount, 2)
        XCTAssertEqual(summary.currencies.map(\.currency), ["EUR", "GBP"])
        XCTAssertEqual(summary.currencies.map(\.totalSpend), [30, 10])
        XCTAssertEqual(summary.currencies.map(\.averageTransaction), [30, 10])
        let empty = MerchantSummary(entries: entries, merchantName: " \n", displayName: { _ in "" })
        XCTAssertEqual(empty.transactionCount, 0)
        XCTAssertTrue(empty.currencies.isEmpty)
    }
}
