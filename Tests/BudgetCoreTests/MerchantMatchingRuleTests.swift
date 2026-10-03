import Foundation
import XCTest
@testable import BudgetCore

final class MerchantMatchingRuleTests: XCTestCase {
    private func match(_ pattern: String, name: String = "Netflix", date: Date = Date()) -> MerchantMatch {
        var match = MerchantMatch(retailer: Retailer(name: name, domain: nil, logo_url: nil), checkedAt: date, isOverride: true)
        match.matchingPattern = pattern
        return match
    }
    private func entry(_ description: String, merchant: String? = nil) -> Entry {
        Entry(id: UUID().uuidString, date: Date(), description: description, amount: -10, account: "Current", merchantName: merchant)
    }

    func testMatchesSelectedFieldWithCaseInsensitiveRegex() throws {
        let rule = try MerchantMatchingRule(owner: "netflix", match: match(#"^netflix\b"#))
        XCTAssertFalse(rule.matches(entry("NETFLIX.COM 123", merchant: "Unrelated bank name")))
        XCTAssertTrue(rule.matches(entry("CARD 123", merchant: "Netflix")))
        XCTAssertFalse(rule.matches(entry("NOT NETFLIX")))
        XCTAssertFalse(rule.matches(entry("NetflixOther")))
        XCTAssertTrue(try MerchantMatchingRule(owner: "unicode", match: match("CAFÉ")).matches(entry("☕ Café")))
    }

    func testInvalidAndEmptyRulesCannotBecomeGlobalRules() throws {
        XCTAssertThrowsError(try MerchantMatchingRule(owner: "bad", match: match("[")))
        XCTAssertTrue(MerchantMatchingRule.compiled(["bad": match("["), "empty": match("")]).isEmpty)
        var automatic = match(".*")
        automatic.isOverride = false
        XCTAssertTrue(MerchantMatchingRule.compiled(["automatic": automatic]).isEmpty)
    }

    func testDescriptionRulesDistinguishBusinessesUsingTheSameProcessor() throws {
        var cafe = match("COFFEE HOUSE", name: "Coffee House")
        cafe.matchDescription = true
        var bakery = match("BAKERY", name: "Bakery")
        bakery.matchDescription = true
        let rules = MerchantMatchingRule.compiled(["cafe": cafe, "bakery": bakery])
        let coffeePayment = entry("ZETTLE * Coffee House", merchant: "Zettle")
        let bakeryPayment = entry("ZETTLE * Bakery", merchant: "Zettle")
        XCTAssertEqual(rules.first { $0.matches(coffeePayment) }?.match.retailer?.name, "Coffee House")
        XCTAssertEqual(rules.first { $0.matches(bakeryPayment) }?.match.retailer?.name, "Bakery")
        XCTAssertNil(rules.first { $0.matches(entry("Other shop", merchant: "Zettle")) })
        XCTAssertFalse(try MerchantMatchingRule(owner: "cafe", match: cafe).matches(entry("Other shop", merchant: "Coffee House")))
        let saved = try JSONDecoder().decode(MerchantMatch.self, from: JSONEncoder().encode(cafe))
        XCTAssertEqual(saved.matchDescription, true)
        let updated = MerchantIconSharing.updating(Retailer(name: "Coffee House", domain: nil, logo_url: "https://example.com/logo.png"), for: coffeePayment, entries: [coffeePayment], matches: ["cafe": cafe])
        XCTAssertEqual(updated["cafe"]?.matchDescription, true)
    }

    func testMostRecentlySavedMatchingRuleWinsForExistingAndNewTransactions() {
        let old = match("NETFLIX", name: "Old name", date: Date(timeIntervalSince1970: 1))
        let new = match("NETFLIX", name: "New name", date: Date(timeIntervalSince1970: 2))
        let rules = MerchantMatchingRule.compiled(["old": old, "new": new])
        for description in ["NETFLIX 123", "NETFLIX 456"] {
            XCTAssertEqual(rules.first { $0.matches(entry(description)) }?.match.retailer?.name, "New name")
        }
    }

    func testRulesSurviveCodingAndIconSharingAndCanBeCleared() throws {
        let transaction = entry("NETFLIX 123")
        let original = match("NETFLIX")
        var matches = [transaction.merchantKey: original]
        let replacement = Retailer(name: "Netflix", domain: nil, logo_url: "https://example.com/logo.png")
        matches = MerchantIconSharing.updating(replacement, for: transaction, entries: [transaction], matches: matches)
        let reopened = try JSONDecoder().decode([String: MerchantMatch].self, from: JSONEncoder().encode(matches))
        XCTAssertEqual(reopened[transaction.merchantKey]?.matchingPattern, "NETFLIX")
        XCTAssertEqual(MerchantMatchingRule.compiled(reopened).count, 1)
        matches[transaction.merchantKey]?.matchingPattern = nil
        XCTAssertTrue(MerchantMatchingRule.compiled(matches).isEmpty)
        // Old saved overrides did not contain this optional field.
        let data = try JSONSerialization.data(withJSONObject: ["retailer": NSNull(), "checkedAt": 0, "isOverride": true])
        XCTAssertNil(try JSONDecoder().decode(MerchantMatch.self, from: data).matchingPattern)
    }

    func testEditorLoadsExistingRuleForPendingAndSharedMerchantNames() {
        let saved = ["original": match("NETFLIX")]
        var pending = entry("NETFLIX 123")
        pending.pending = true
        XCTAssertEqual(MerchantMatchingRule.forEditing(entry: pending, matches: saved, displayName: "Netflix")?.match.matchingPattern, "NETFLIX")
        let renamed = entry("CARD PAYMENT")
        let rule = MerchantMatchingRule.forEditing(entry: renamed, matches: saved, displayName: "Net Flix")
        XCTAssertEqual(rule?.owner, "original")
        XCTAssertEqual(rule?.match.matchingPattern, "NETFLIX")
        XCTAssertNil(MerchantMatchingRule.forEditing(entry: renamed, matches: saved, displayName: "Other merchant"))
    }

    func testEditorPrefersActiveRuleAndCanReopenNonMatchingOwnedRule() {
        let transaction = entry("NETFLIX 123")
        let saved = [transaction.merchantKey: match("FUTURE TEXT"), "active": match("NETFLIX")]
        XCTAssertEqual(MerchantMatchingRule.forEditing(entry: transaction, matches: saved, displayName: "Netflix")?.owner, "active")
        XCTAssertEqual(MerchantMatchingRule.forEditing(entry: transaction, matches: [transaction.merchantKey: saved[transaction.merchantKey]!], displayName: "Netflix")?.match.matchingPattern, "FUTURE TEXT")
    }
}
