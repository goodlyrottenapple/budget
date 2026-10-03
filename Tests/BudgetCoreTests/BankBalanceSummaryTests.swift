import Foundation
import Testing
@testable import BudgetCore

private func balanceAccount(_ id: String, _ balance: String?, currency: String = "GBP", kind: String = "accounts") -> BankAccount {
    BankAccount(id: id, name: id, kind: kind, currency: currency, current: balance, transactionCount: 0)
}

@Test func balanceTotalSubtractsCardDebtInTheRequestedCurrency() {
    let accounts = [balanceAccount("barclays", "4097.64"), balanceAccount("natwest", "1728.65"),
                    balanceAccount("lloyds", "2026.98"), balanceAccount("amex", "900.00", kind: "cards"),
                    balanceAccount("euros", "500.00", currency: "EUR"),
                    balanceAccount("euro-card", "50.00", currency: "EUR", kind: "cards")]
    let summary = BankBalanceSummary(accounts: accounts, currency: "GBP")
    #expect(summary.accountCount == 4)
    #expect(summary.total == Decimal(string: "6953.27"))
    #expect(BankBalanceSummary(accounts: accounts, currency: "EUR").total == 450)
}

@Test func balanceTotalPreservesOverdraftsAndExactPennies() {
    let summary = BankBalanceSummary(accounts: [balanceAccount("positive", "100.11"),
                                               balanceAccount("overdraft", "-120.23")], currency: "GBP")
    #expect(summary.total == Decimal(string: "-20.12"))
}

@Test func missingOrMalformedBalancesDoNotProducePartialTotals() {
    for value in [nil, "", "NaN", "unknown", "25.00invalid"] as [String?] {
        let summary = BankBalanceSummary(accounts: [balanceAccount("known", "150"),
                                                   balanceAccount("missing", value)], currency: "GBP")
        #expect(summary.total == nil)
        #expect(summary.accountCount == 2)
    }
    #expect(BankBalanceSummary(accounts: [], currency: "GBP").total == nil)
}

@Test func missingCardBalancesDoNotProducePartialTotals() {
    let summary = BankBalanceSummary(accounts: [balanceAccount("zero", "0.00"),
                                               balanceAccount("card", nil, kind: "cards")], currency: "GBP")
    #expect(summary.total == nil)
    #expect(summary.accountCount == 2)
}

@Test func cardBalancesRepresentDebtAndOverpaymentWithoutChangingStoredValues() {
    let debt = balanceAccount("debt", "900.12", kind: "cards")
    let credit = balanceAccount("credit", "-20.23", kind: "cards")
    let zero = balanceAccount("zero", "0.00", kind: "cards")
    #expect(debt.currentBalance == Decimal(string: "900.12"))
    #expect(debt.netBalance == Decimal(string: "-900.12"))
    #expect(credit.netBalance == Decimal(string: "20.23"))
    #expect(zero.netBalance == 0)
    #expect(BankBalanceSummary(accounts: [debt, credit, zero], currency: "GBP").total == Decimal(string: "-879.89"))
    #expect(BankBalanceSummary(accounts: [zero], currency: "GBP").total == 0)
}

@Test func importedBalanceIncludesOnlyCurrentMonthPurchasesRefundsAndRepayments() throws {
    let entries = try CSVImport.parse("""
    date,description,amount,account,category
    2026-08-01,Purchase,-200.15,Yonder,Shopping
    2026-09-01,Purchase,-50.12,Yonder,Other
    2026-09-02,Refund,20.10,Yonder,Shopping
    2026-09-03,Repayment,100.00,Yonder,Transfer
    """)
    let balance = ImportedAccountBalance.balance(entries: entries, account: "Yonder", currency: "GBP",
                                                  asOf: try BankSync.date("2026-09-16T12:00:00Z"))
    #expect(balance == Decimal(string: "69.98"))
    #expect(BankBalanceSummary(accounts: [balanceAccount("bank", "500"),
                                         balanceAccount("card", "100", kind: "cards")],
                               currency: "GBP", importedBalance: balance).total == Decimal(string: "469.98"))
}

@Test func importedBalanceUsesLocalMonthBoundaryAndResetsForNewMonth() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "Europe/London"))
    let entries = [
        Entry(id: "yonder:previous", date: try BankSync.date("2026-08-31T22:59:59Z"), description: "Previous month", amount: -100, account: "Yonder"),
        Entry(id: "yonder:current", date: try BankSync.date("2026-08-31T23:00:00Z"), description: "First of September", amount: -15, account: "Yonder")
    ]
    #expect(ImportedAccountBalance.balance(entries: entries, account: "Yonder", currency: "GBP",
        asOf: try BankSync.date("2026-09-16T12:00:00Z"), calendar: calendar) == -15)
    #expect(ImportedAccountBalance.balance(entries: entries, account: "Yonder", currency: "GBP",
        asOf: try BankSync.date("2026-09-30T23:00:00Z"), calendar: calendar) == 0)
}

@Test func importedBalanceExcludesOtherAccountsCurrenciesFutureEntriesAndBankData() throws {
    let now = try BankSync.date("2026-09-16T12:00:00Z")
    let entries = [
        Entry(id: "yonder:purchase", date: now, description: "Purchase", amount: -25, account: "Yonder"),
        Entry(id: "csv:other", date: now, description: "Other account", amount: -100, account: "Other"),
        Entry(id: "csv:euro", date: now, description: "Euro", amount: -100, currency: "EUR", account: "Yonder"),
        Entry(id: "csv:future", date: now.addingTimeInterval(86400), description: "Future", amount: -100, account: "Yonder"),
        Entry(id: "truelayer:bank", date: now, description: "Bank", amount: -100, account: "Yonder")
    ]
    #expect(ImportedAccountBalance.balance(entries: entries, account: "Yonder", currency: "GBP", asOf: now) == -25)
}

@Test func importedBalanceDistinguishesNoHistoryFromRepaidBalanceAndCredit() throws {
    let now = Date()
    let purchase = Entry(id: "yonder:purchase", date: now, description: "Purchase", amount: -25, account: "Yonder")
    let repayment = Entry(id: "yonder:repayment", date: now, description: "Repayment", amount: 25, account: "Yonder", category: .transfer)
    #expect(ImportedAccountBalance.balance(entries: [], account: "Yonder", currency: "GBP", asOf: now) == nil)
    #expect(ImportedAccountBalance.balance(entries: [purchase, repayment], account: "Yonder", currency: "GBP", asOf: now) == 0)
    #expect(ImportedAccountBalance.balance(entries: [repayment], account: "Yonder", currency: "GBP", asOf: now) == 25)
    #expect(BankBalanceSummary(accounts: [], currency: "GBP", importedBalance: -25).total == -25)
    #expect(BankBalanceSummary(accounts: [], currency: "GBP", importedBalance: 0).total == 0)
    #expect(BankBalanceSummary(accounts: [balanceAccount("missing", nil)], currency: "GBP", importedBalance: -25).total == nil)
}
