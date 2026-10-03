import Foundation
import XCTest
@testable import BudgetCore

final class ReimbursementTests: XCTestCase {
    func testPartialAndFullReimbursementReduceMonthlyAndCategorySpending() {
        let date = Date()
        var expense = Entry(id: "one", date: date, description: "Work dinner", amount: -100, account: "Amex", category: .dining)
        expense.reimbursement = 40
        XCTAssertEqual(expense.reimbursementStatus, "Partially reimbursed")
        XCTAssertEqual(BudgetMath.spending([expense], currency: "GBP", month: date), 60)
        XCTAssertEqual(BudgetMath.spending([expense], currency: "GBP", month: date, category: .dining), 60)
        XCTAssertEqual(BudgetMath.spending([expense], currency: "GBP", month: date, category: .travel), 0)
        XCTAssertEqual(expense.amount, -100)
        expense.reimbursement = 100
        XCTAssertEqual(expense.reimbursementStatus, "Reimbursed")
        XCTAssertEqual(BudgetMath.spending([expense], currency: "GBP", month: date), 0)
        expense.reimbursement = nil
        XCTAssertNil(expense.reimbursementStatus)
        XCTAssertEqual(BudgetMath.spending([expense], currency: "GBP", month: date), 100)
    }

    func testReimbursementsDoNotAlterBalancesOrMakeExpenseNegativeAfterBankCorrection() {
        let date = Date()
        var expense = Entry(id: "yonder:one", date: date, description: "Work dinner", amount: -60, account: "Yonder", category: .dining)
        expense.reimbursement = 100
        XCTAssertEqual(BudgetMath.spending([expense], currency: "GBP", month: date), 0)
        XCTAssertEqual(ImportedAccountBalance.balance(entries: [expense], account: "Yonder", currency: "GBP", asOf: date), -60)
        var refund = expense
        refund.amount = 20
        XCTAssertNil(refund.reimbursementStatus)
        XCTAssertEqual(BudgetMath.spending([refund], currency: "GBP", month: date), -20)
        expense.category = .transfer
        XCTAssertEqual(BudgetMath.spending([expense], currency: "GBP", month: date), 0)
    }

    func testReimbursementValidationAcceptsCurrencyDecimalsAndRejectsInvalidInput() throws {
        let expense = Entry(id: "one", date: Date(), description: "Work", amount: -100, account: "Amex")
        let locale = Locale(identifier: "en_GB")
        XCTAssertEqual(try expense.validatedReimbursement(" 12.34 ", locale: locale), Decimal(string: "12.34"))
        XCTAssertEqual(try expense.validatedReimbursement("12,34", locale: Locale(identifier: "de_DE")), Decimal(string: "12.34"))
        XCTAssertEqual(try expense.validatedReimbursement("", locale: locale), 0)
        XCTAssertEqual(try expense.validatedReimbursement("100", locale: locale), 100)
        for text in ["-1", "100.01", "12abc", "NaN", "1.234", "1.2.3"] {
            XCTAssertThrowsError(try expense.validatedReimbursement(text, locale: locale))
        }
    }

    func testOlderTransactionsDecodeWithoutReimbursement() throws {
        let entry = Entry(id: "old", date: Date(), description: "Old transaction", amount: -5, account: "Yonder")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        json.removeValue(forKey: "reimbursement")
        let decoded = try JSONDecoder().decode(Entry.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(decoded.reimbursement)
        XCTAssertNil(decoded.reimbursementStatus)
    }
}
