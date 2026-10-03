import Foundation
import XCTest
@testable import BudgetCore

final class RecurringPaymentsTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private func date(_ month: Int, _ day: Int = 10) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day))!
    }
    private func payment(_ id: String, month: Int, amount: Decimal = -25, recurring: Bool = false) -> Entry {
        var entry = Entry(id: "truelayer:bank:accounts:one:\(id)", date: date(month), description: "Gym", amount: amount, account: "Current", category: .healthAndBeauty)
        entry.recurringMonthly = recurring ? true : nil
        return entry
    }
    private func outstanding(_ entries: [Entry], month: Int = 9) -> [Entry] {
        RecurringPayments.outstanding(entries, month: date(month), now: date(9), calendar: calendar)
    }

    func testReservesLatestAmountOnceAndNeverChangesPastMonths() {
        let original = payment("old", month: 7, recurring: true)
        let latest = payment("new", month: 8, amount: -30, recurring: true)
        XCTAssertEqual(outstanding([original, latest]).map(\.amount), [-30])
        XCTAssertTrue(outstanding([original], month: 8).isEmpty)
        XCTAssertTrue(outstanding([payment("current", month: 9, recurring: true)]).isEmpty)
    }

    func testPendingOrSettledPaymentReplacesEstimateEvenWithDifferentAmount() {
        let original = payment("old", month: 8, recurring: true)
        var incoming = payment("new", month: 9, amount: -32)
        incoming.description = " G Y M "
        incoming.pending = true
        XCTAssertTrue(outstanding([original, incoming]).isEmpty)
        incoming.pending = nil
        XCTAssertTrue(outstanding([original, incoming]).isEmpty)
        XCTAssertEqual(outstanding([original, incoming], month: 10).first?.amount, -32)
    }

    func testOtherAccountsCurrenciesAndRefundsDoNotSuppressEstimate() {
        let original = payment("old", month: 8, recurring: true)
        var otherAccount = payment("new", month: 9)
        otherAccount.id = "truelayer:bank:accounts:two:new"
        var otherCurrency = payment("euro", month: 9)
        otherCurrency.currency = "EUR"
        let refund = payment("refund", month: 9, amount: 25)
        XCTAssertEqual(outstanding([original, otherAccount, otherCurrency, refund]).count, 1)
    }

    func testExcludedCategoriesAndDisabledRecurringAreNotReserved() {
        for category in [Category.transfer, .savings, .income] {
            var original = payment("old", month: 8, recurring: true)
            original.category = category
            XCTAssertTrue(outstanding([original]).isEmpty)
        }
        XCTAssertTrue(outstanding([payment("old", month: 8)]).isEmpty)
    }

    func testCustomMerchantNamesMatchAndReimbursementIsPreserved() {
        var original = payment("old", month: 8, recurring: true)
        original.reimbursement = 10
        XCTAssertEqual(outstanding([original]).first?.reimbursedAmount, 10)
        var incoming = payment("new", month: 9)
        incoming.description = "Different bank description"
        let result = RecurringPayments.outstanding([original, incoming], month: date(9), now: date(9), calendar: calendar, merchantName: { _ in "My Gym" })
        XCTAssertTrue(result.isEmpty)
    }
}
