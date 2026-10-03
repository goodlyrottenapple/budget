import Foundation
import XCTest
@testable import BudgetCore

final class BudgetCoreTests: XCTestCase {
func testOverviewMonthsSkipEmptyAndFutureMonths() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
    let formatter = ISO8601DateFormatter()
    let now = try XCTUnwrap(formatter.date(from: "2026-09-17T12:00:00Z"))
    let dates = ["2026-06-10T12:00:00Z", "2026-06-20T12:00:00Z", "2026-08-01T00:00:00Z", "2026-10-01T12:00:00Z"]
    let entries = try dates.enumerated().map { index, date in
        Entry(id: String(index), date: try XCTUnwrap(formatter.date(from: date)), description: "Shop", amount: -10, account: "Test")
    }
    let months = OverviewMonths.available(entries: entries, now: now, calendar: calendar)
    XCTAssertEqual(months.map { calendar.component(.month, from: $0) }, [6, 8, 9])
    XCTAssertEqual(OverviewMonths.available(entries: [], now: now, calendar: calendar), [try XCTUnwrap(months.last)])
}

func testRemovedWorkshopCategoryRemainsReadableAsOther() throws {
    XCTAssertFalse(BudgetCore.Category.allCases.contains { $0.rawValue == "Workshop" })
    XCTAssertEqual(try JSONDecoder().decode(BudgetCore.Category.self, from: Data(#""Workshop""#.utf8)), .other)
}

func testTransactionsGroupByLocalDateNewestFirst() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
    let formatter = ISO8601DateFormatter()
    let early = try XCTUnwrap(formatter.date(from: "2026-08-12T22:30:00Z"))
    let nextDay = try XCTUnwrap(formatter.date(from: "2026-08-12T23:30:00Z"))
    let later = try XCTUnwrap(formatter.date(from: "2026-08-13T10:00:00Z"))
    let entries = [Entry(id: "early", date: early, description: "Shop", amount: -5, account: "Yonder"),
                   Entry(id: "next", date: nextDay, description: "Shop", amount: -5, account: "Yonder"),
                   Entry(id: "later", date: later, description: "Shop", amount: -5, account: "Yonder")]
    let days = TransactionGrouping.days(entries, calendar: calendar)
    XCTAssertEqual(days.count, 2)
    XCTAssertEqual(days[0].entries.map(\.id), ["later", "next"])
    XCTAssertEqual(days[1].entries.map(\.id), ["early"])
}

func testTransportCategoryMigratesToTravel() throws {
    let category = try JSONDecoder().decode(BudgetCore.Category.self, from: Data(#""Transport""#.utf8))
    XCTAssertEqual(category, .travel)
    let encoded = try JSONEncoder().encode(category)
    XCTAssertEqual(String(data: encoded, encoding: .utf8), #""Travel""#)
    let csv = try CSVImport.parse("date,description,amount,category\n2026-09-12,Train,-12,Transport\n")
    XCTAssertEqual(csv[0].category, .travel)
}

func testMerchantRulesMatchAcrossAccountsAndApplyToFutureArrivals() {
    let date = Date()
    let entries = [
        Entry(id: "1", date: date, description: "  Coffee   Shop ", amount: -5, account: "Yonder"),
        Entry(id: "2", date: date, description: "COFFEE SHOP", amount: -7, account: "Revolut"),
        Entry(id: "3", date: date, description: "Coffee Shop Express", amount: -9, account: "Yonder")
    ]
    var rules: [String: BudgetCore.Category] = [:]
    let changed = Categorisation.update(entries, transactionID: "1", category: .dining, allFromMerchant: true, rules: &rules)
    XCTAssertEqual(changed[0].category, .dining)
    XCTAssertEqual(changed[1].category, .dining)
    XCTAssertEqual(changed[2].category, .other)
    let future = Entry(id: "4", date: date, description: "coffee shop", amount: -3, account: "Lloyds", category: .shopping)
    XCTAssertEqual(Categorisation.apply(to: future, rules: rules).category, .dining)
}

func testSingleTransactionExceptionAndExplicitAllReplacement() throws {
    let date = Date()
    let entries = [Entry(id: "1", date: date, description: "Store", amount: -5, account: "Yonder"), Entry(id: "2", date: date, description: "Store", amount: -10, account: "Revolut")]
    var rules = ["store": BudgetCore.Category.shopping]
    let one = Categorisation.update(entries, transactionID: "1", category: .groceries, allFromMerchant: false, rules: &rules)
    XCTAssertEqual(one[0].categoryOverride, .groceries)
    XCTAssertEqual(one[1].category, .other)
    XCTAssertEqual(rules["store"], .shopping)
    XCTAssertEqual(Categorisation.apply(to: one[0], rules: rules).category, .groceries)
    let roundTrip = try JSONDecoder().decode([Entry].self, from: JSONEncoder().encode(one))
    XCTAssertEqual(roundTrip[0].categoryOverride, .groceries)
    let all = Categorisation.update(roundTrip, transactionID: "2", category: .dining, allFromMerchant: true, rules: &rules)
    XCTAssertEqual(all[0].category, .dining)
    XCTAssertNil(all[0].categoryOverride)
    XCTAssertEqual(rules["store"], .dining)
}

func testMerchantNameTakesPrecedenceOverVariableBankDescription() {
    let entry = Entry(id: "1", date: Date(), description: "STORE CARD 1234 LONDON", amount: -5, account: "Revolut", merchantName: "Store")
    XCTAssertEqual(Categorisation.apply(to: entry, rules: ["store": .shopping]).category, .shopping)
    XCTAssertEqual(entry.magnitude, 5)
    var refund = entry; refund.amount = 5
    XCTAssertEqual(refund.magnitude, 5)
}

func testProviderCatalogueAndCardOnlyAuthorisation() throws {
    let json = #"[{"provider_id":"ob-amex","display_name":"American Express","country":"uk","logo_url":"https://providers-assets.truelayer.com/ob-amex/logo.svg","scopes":["cards","balance","transactions","offline_access"],"availability":{"recommended_status":"healthy"}},{"provider_id":"mock","display_name":"Mock","country":"uk","scopes":["accounts","transactions"]},{"provider_id":"foreign","display_name":"Foreign","country":"ie","scopes":["accounts","transactions"]}]"#
    let providers = try JSONDecoder().decode([BankProvider].self, from: Data(json.utf8))
    XCTAssertEqual(providers.filter(\.isUKDataProvider).count, 1)
    XCTAssertEqual(providers[0].availability?.status, "healthy")
    let url = try XCTUnwrap(providers[0].authorisationURL(clientID: "test-client", redirectURI: "https://example.com/callback", state: "test-state"))
    let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
    XCTAssertEqual(query.first(where: { $0.name == "scope" })?.value, "cards balance transactions offline_access")
    XCTAssertEqual(query.first(where: { $0.name == "providers" })?.value, "ob-amex")
    XCTAssertEqual(query.first(where: { $0.name == "provider_id" })?.value, "ob-amex")
    XCTAssertEqual(query.first(where: { $0.name == "state" })?.value, "test-state")
}

func testProviderMatchesDataAPIIdentifiersWithoutMixingBusinessAccounts() throws {
    let json = #"{"provider_id":"ob-lloyds","display_name":"Lloyds","country":"uk","scopes":["accounts","transactions"]}"#
    let provider = try JSONDecoder().decode(BankProvider.self, from: Data(json.utf8))
    XCTAssertTrue(provider.matchesAccountProviderID("ob-lloyds"))
    XCTAssertTrue(provider.matchesAccountProviderID("lloyds"))
    XCTAssertTrue(provider.matchesAccountProviderID("uk-ob-lloyds"))
    XCTAssertTrue(provider.matchesAccountProviderID("gb-ob-lloyds"))
    XCTAssertFalse(provider.matchesAccountProviderID("lloyds-business"))
    XCTAssertFalse(provider.matchesAccountProviderID("natwest"))
    XCTAssertFalse(provider.matchesAccountProviderID(nil))
}

func testOldTransactionsDecodeWithoutProviderID() throws {
    let json = #"{"id":"legacy","date":0,"description":"Old transaction","amount":-5,"currency":"GBP","account":"Yonder","category":"Other"}"#
    let entry = try JSONDecoder().decode(Entry.self, from: Data(json.utf8))
    XCTAssertNil(entry.providerID)
}

func testYonderUsesGBPAmountAndDebitCreditDirection() throws {
    let header = "Date/Time of transaction,Description,Amount (GBP),Amount (in Charged Currency),Currency,Category,Debit or Credit,Country\n"
    let csv = header + "2026-09-12T10:20:30.123456,Synthetic shop,25.50,30.00,EUR,Groceries,Debit,FR\n2026-09-13T10:20:30.000000,Synthetic refund,5.50,6.00,EUR,Groceries,Credit,FR\n2026-09-14T10:20:30.000000,Card repayment,100.00,100.00,GBP,Other,Credit,GB\n"
    let entries = try CSVImport.parse(csv)
    XCTAssertEqual(entries.count, 3)
    XCTAssertEqual(entries[0].amount, Decimal(string: "-25.50"))
    XCTAssertEqual(entries[0].currency, "GBP")
    XCTAssertEqual(entries[0].category, .groceries)
    XCTAssertEqual(entries[1].amount, Decimal(string: "5.50"))
    XCTAssertEqual(entries[2].category, .transfer)
    XCTAssertEqual(entries[0].id, try CSVImport.parse(csv)[0].id)
    let month = entries[0].date
    XCTAssertEqual(BudgetMath.spending(entries, currency: "GBP", month: month), 20)
    XCTAssertThrowsError(try CSVImport.parse(header + "2026-09-12T10:20:30.123456,Shop,25.50,30.00,EUR,Groceries,Unknown,FR\n"))
}

func testCSVHandlesQuotesAndStableIDs() throws {
    let csv = "date,description,amount,currency,account,id,category\r\n2026-09-12,\"Cafe, \"\"London\"\"\",-12.50,GBP,Yonder,abc,Dining\r\n"
    let first = try CSVImport.parse(csv)
    let second = try CSVImport.parse(csv)
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(first[0].description, "Cafe, \"London\"")
    XCTAssertEqual(first[0].amount, Decimal(string: "-12.50"))
    XCTAssertEqual(first[0].id, second[0].id)
}

func testRejectsMalformedAmountsAndDates() {
    for row in ["2026-02-30,Cafe,-2", "2026-09-12,Cafe,12oops", "2026-09-12,\"Cafe,-2"] {
        XCTAssertThrowsError(try CSVImport.parse("date,description,amount\n" + row))
    }
}

func testBudgetsExcludeTransfersSavingsIncomeAndOtherCurrenciesAndOffsetRefunds() {
    let date = Date()
    let entries = [
        Entry(id: "1", date: date, description: "Shop", amount: -50, account: "Revolut", category: .shopping),
        Entry(id: "2", date: date, description: "Refund", amount: 10, account: "Revolut", category: .shopping),
        Entry(id: "3", date: date, description: "Card repayment", amount: -100, account: "Revolut", category: .transfer),
        Entry(id: "4", date: date, description: "Euro purchase", amount: -20, currency: "EUR", account: "Revolut", category: .shopping),
        Entry(id: "5", date: date, description: "Savings deposit", amount: -200, account: "Revolut", category: .savings),
        Entry(id: "6", date: date, description: "Savings withdrawal", amount: 75, account: "Revolut", category: .savings),
        Entry(id: "7", date: date, description: "Salary", amount: 3000, account: "Revolut", category: .income)
    ]
    XCTAssertEqual(BudgetMath.spending(entries, currency: "GBP", month: date), 40)
    XCTAssertEqual(BudgetMath.spending(entries, currency: "GBP", month: date, category: .savings), 0)
}

}
