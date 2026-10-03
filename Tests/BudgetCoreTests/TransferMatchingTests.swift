import Foundation
import XCTest
@testable import BudgetCore

final class TransferMatchingTests: XCTestCase {
    private let day = Date(timeIntervalSince1970: 1_789_171_200)
    private func entry(_ id: String, amount: Decimal, account: String = "Bank", currency: String = "GBP", offset: TimeInterval = 0) -> Entry {
        Entry(id: id, date: day.addingTimeInterval(offset), description: id, amount: amount,
              currency: currency, account: account, category: amount > 0 ? .income : .other)
    }
    func testPairIsExcludedWithoutChangingOriginalRecords() {
        let original = [entry("payment", amount: -150), entry("repayment", amount: 150, account: "Amex", offset: 3600)]
        let matched = TransferMatching.apply(to: original)
        XCTAssertEqual(matched.map(\.category), [.transfer, .transfer])
        XCTAssertEqual(BudgetMath.spending(matched, currency: "GBP", month: day), 0)
        XCTAssertEqual(original[0].category, .other)
        XCTAssertEqual(TransferMatching.apply(to: [original[0]])[0].category, .other)
        XCTAssertEqual(TransferMatching.apply(to: matched).map(\.category), [.transfer, .transfer])
    }
    func testDifferentDaysCurrenciesDirectionsAndSameAccountDoNotMatch() {
        let payment = entry("payment", amount: -150)
        for other in [entry("next day", amount: 150, account: "Amex", offset: 86400),
                      entry("currency", amount: 150, account: "Amex", currency: "EUR"),
                      entry("outgoing", amount: -150, account: "Amex"),
                      entry("same account", amount: 150),
                      entry("different amount", amount: Decimal(string: "150.01")!, account: "Amex")] {
            XCTAssertEqual(TransferMatching.apply(to: [payment, other])[0].category, .other)
        }
        XCTAssertFalse(TransferMatching.apply(to: [entry("zero1", amount: 0), entry("zero2", amount: 0, account: "Amex")]).contains { $0.category == .transfer })
    }
    func testAmbiguousPairsAndManualChoicesArePreserved() {
        let payment = entry("payment", amount: -150)
        let repayment = entry("repayment", amount: 150, account: "Amex")
        XCTAssertFalse(TransferMatching.apply(to: [payment, repayment, entry("duplicate", amount: -150)]).contains { $0.category == .transfer })
        var manual = payment
        manual.category = .house; manual.categoryOverride = .house; manual.notes = "Keep this"
        let result = TransferMatching.apply(to: [manual, repayment])
        XCTAssertEqual(result[0].category, .house)
        XCTAssertEqual(result[0].notes, "Keep this")
        XCTAssertEqual(result[1].category, .income)
        XCTAssertEqual(TransferMatching.apply(to: [payment, repayment], rules: [payment.merchantKey: .house])[0].category, .other)
    }
    func testBankAccountIdentityUsesIDsEvenWithIdenticalNames() {
        let first = entry("truelayer:ob-amex:cards:one:stable:1", amount: -150, account: "Card")
        let second = entry("truelayer:ob-amex:cards:two:stable:2", amount: 150, account: "Card")
        XCTAssertEqual(TransferMatching.apply(to: [first, second]).map(\.category), [.transfer, .transfer])
        let same = entry("truelayer:ob-amex:cards:one:stable:2", amount: 150, account: "Renamed card")
        XCTAssertEqual(TransferMatching.apply(to: [first, same])[0].category, .other)
    }
}
