import Foundation

// Standalone checks for machines whose Command Line Tools lack XCTest.
@main
struct CoreChecks {
    static func main() throws {
        let header = "Date/Time of transaction,Description,Amount (GBP),Amount (in Charged Currency),Currency,Category,Debit or Credit,Country\n"
        let csv = header + "2026-09-12T10:20:30.123456,Synthetic shop,25.50,30.00,EUR,Groceries,Debit,FR\n2026-09-13T10:20:30.000000,Synthetic refund,5.50,6.00,EUR,Groceries,Credit,FR\n2026-09-14T10:20:30.000000,Card repayment,100.00,100.00,GBP,Other,Credit,GB\n"
        let entries = try CSVImport.parse(csv)
        precondition(entries.count == 3)
        precondition(entries[0].amount == Decimal(string: "-25.50"))
        precondition(entries[0].currency == "GBP")
        precondition(entries[0].category == .groceries)
        precondition(entries[1].amount == Decimal(string: "5.50"))
        precondition(entries[2].category == .transfer)
        let repeated = try CSVImport.parse(csv)
        precondition(entries[0].id == repeated[0].id)
        precondition(BudgetMath.spending(entries, currency: "GBP", month: entries[0].date) == 20)
        let quoted = try CSVImport.parse("date,description,amount\n2026-09-12,\"Cafe, \"\"London\"\"\",-12.50\n")
        precondition(quoted[0].description == "Cafe, \"London\"")
        for malformed in ["2026-02-30,Cafe,-2", "2026-09-12,Cafe,12oops", "2026-09-12,\"Cafe,-2"] {
            do {
                _ = try CSVImport.parse("date,description,amount\n" + malformed)
                fatalError("Invalid CSV accepted")
            } catch is CSVError { }
        }
        let euro = Entry(id: "eur", date: entries[0].date, description: "Euro purchase", amount: -500, currency: "EUR", account: "Revolut", category: .shopping)
        precondition(BudgetMath.spending(entries + [euro], currency: "GBP", month: entries[0].date) == 20)
        print("PASS: Yonder debit/credit signs, settled GBP, refunds, repayments, stable identities, CSV quoting, malformed input, and currency isolation")
        if CommandLine.arguments.count > 1 {
            let sample = try CSVImport.parse(String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8))
            precondition(!sample.isEmpty)
            precondition(sample.allSatisfy { $0.currency == "GBP" && $0.account == "Yonder" })
            print("PASS: supplied Yonder CSV parsed (\(sample.count) rows; no transaction details printed)")
        }
    }
}
