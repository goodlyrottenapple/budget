import Foundation
import XCTest
@testable import BudgetCore

final class DemoDatasetTests: XCTestCase {
    func testDemoIncludesThreeMonthsWithoutFutureTransactionsEvenOnFirstDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!
        let data = DemoDataset(now: now, calendar: calendar)
        XCTAssertEqual(data.entries.count, 36)
        XCTAssertEqual(Set(data.entries.map(\.id)).count, data.entries.count)
        XCTAssertTrue(data.entries.allSatisfy { $0.date <= now })
        XCTAssertEqual(Set(data.entries.map { calendar.dateInterval(of: .month, for: $0.date)!.start }).count, 3)
        XCTAssertTrue(data.entries.contains(where: \.isPending))
        XCTAssertTrue(data.entries.contains { $0.reimbursedAmount > 0 })
        XCTAssertNotNil(ImportedAccountBalance.balance(entries: data.entries, account: "Yonder", currency: "GBP", asOf: now, calendar: calendar))
        for provider in data.providers {
            for account in data.accounts[provider.id] ?? [] {
                let transactions = data.entries.filter { $0.id.hasPrefix(account.id) }
                XCTAssertEqual(transactions.count, account.transactionCount)
                XCTAssertTrue(transactions.allSatisfy { $0.providerID == provider.id && $0.bankAccountKind == account.kind })
                if account.kind == "cards" { XCTAssertLessThan(account.netBalance!, 0) }
            }
        }
    }
}
