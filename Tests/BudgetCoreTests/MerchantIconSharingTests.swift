import Foundation
import XCTest
@testable import BudgetCore

final class MerchantIconSharingTests: XCTestCase {
    func testEmptyNameDefaultsToOriginal() {
        XCTAssertEqual(MerchantIconSharing.resolvedName(" \n\t", original: "Bank description"), "Bank description")
        XCTAssertEqual(MerchantIconSharing.resolvedName(" Coffee Shop ", original: "Bank description"), "Coffee Shop")
    }

    func testSuggestionsDeduplicateNamesAndUseLatestIconIncludingRemoval() {
        let old = Retailer(name: "Coffee Shop", domain: nil, logo_url: nil, customIconData: Data([1]))
        let removed = Retailer(name: "COFFEEshop", domain: nil, logo_url: nil)
        let other = Retailer(name: "The Coffee Place", domain: nil, logo_url: nil, customIconData: Data([2]))
        let matches = [
            "alias a": MerchantMatch(retailer: old, checkedAt: Date(timeIntervalSince1970: 1), isOverride: true),
            "alias b": MerchantMatch(retailer: removed, checkedAt: Date(timeIntervalSince1970: 2), isOverride: true),
            "alias c": MerchantMatch(retailer: other, isOverride: true)
        ]
        let index = MerchantIconSharing.index(matches: matches)
        let suggestions = MerchantIconSharing.suggestions(for: " C oFfEe ", index: index)
        XCTAssertEqual(suggestions.map(\.name), ["COFFEEshop", "The Coffee Place"])
        XCTAssertNil(suggestions.first?.customIconData)
        XCTAssertEqual(suggestions.last?.customIconData, Data([2]))
        XCTAssertEqual(MerchantIconSharing.suggestions(for: "coffee", index: index, limit: 1).count, 1)
        XCTAssertTrue(MerchantIconSharing.suggestions(for: " \n", index: index).isEmpty)
        XCTAssertTrue(MerchantIconSharing.suggestions(for: "unmatched", index: index).isEmpty)
    }

    private func entry(_ name: String, account: String = "Bank") -> Entry {
        Entry(id: name + account, date: Date(), description: name, amount: -10, account: account)
    }
    func testRenameUsesExistingArtworkWithoutOverwritingEnteredName() {
        let icon = Retailer(name: "Coffee Shop", domain: "coffee.example", logo_url: "https://img.logo.dev/coffee.example")
        let matches = ["coffee shop": MerchantMatch(retailer: icon, isOverride: true)]
        let existing = MerchantIconSharing.index(matches: matches)[MerchantSummary.normalisedName(" COFFEE\tSHOP ")]!
        let draft = Retailer(name: "coffeeSHOP", domain: nil, logo_url: nil)
        let updated = MerchantIconSharing.applyingIcon(existing, to: draft)
        XCTAssertEqual(updated.name, "coffeeSHOP")
        XCTAssertEqual(updated.logoURL, icon.logoURL)
    }

    func testReplacementAndRemovalApplyToAliasesAcrossAccountsAndSurviveEncoding() throws {
        let a = entry("BANK COFFEE 123"), b = entry("CARD COFFEE", account: "Card")
        let raw = entry("COFFEE\tSHOP"), other = entry("Other")
        let image = Data([1, 2, 3])
        let old = Retailer(name: "Coffee Shop", domain: nil, logo_url: nil, customIconData: image)
        var matches = [MerchantRecognition.key(for: a.merchant): MerchantMatch(retailer: old, isOverride: true),
                       MerchantRecognition.key(for: b.merchant): MerchantMatch(retailer: Retailer(name: "coffeeSHOP", domain: nil, logo_url: nil, customIconData: image), isOverride: true),
                       "other": MerchantMatch(retailer: Retailer(name: "Other", domain: nil, logo_url: nil, customIconData: image), isOverride: true)]
        let replacement = Retailer(name: "Coffee Shop", domain: "coffee.example", logo_url: "https://img.logo.dev/coffee.example")
        matches = MerchantIconSharing.updating(replacement, for: a, entries: [a,b,raw,other], matches: matches)
        for transaction in [a,b,raw] {
            let saved = matches[MerchantRecognition.key(for: transaction.merchant)]!
            XCTAssertEqual(saved.retailer?.logoURL, replacement.logoURL)
            XCTAssertNil(saved.retailer?.customIconData)
        }
        XCTAssertEqual(matches[MerchantRecognition.key(for: b.merchant)]?.retailer?.name, "coffeeSHOP")
        XCTAssertEqual(matches["other"]?.retailer?.customIconData, image)
        let removed = Retailer(name: "Coffee Shop", domain: nil, logo_url: nil)
        matches = MerchantIconSharing.updating(removed, for: a, entries: [a,b,raw,other], matches: matches)
        matches = try JSONDecoder().decode([String: MerchantMatch].self, from: JSONEncoder().encode(matches))
        // A later automatic match must not resurrect artwork that the user removed.
        matches["coffee  shop"] = MerchantMatch(retailer: replacement, checkedAt: Date().addingTimeInterval(100))
        let shared = try XCTUnwrap(MerchantIconSharing.index(matches: matches)["coffeeshop"])
        XCTAssertNil(shared.logoURL)
        XCTAssertNil(shared.customIconData)
        for transaction in [a,b,raw] {
            XCTAssertNil(matches[MerchantRecognition.key(for: transaction.merchant)]?.retailer?.customIconData)
            XCTAssertNil(matches[MerchantRecognition.key(for: transaction.merchant)]?.retailer?.logoURL)
        }
    }

    func testRenameDoesNotChangeArtworkForOldNameOrPromoteRejectedAutomaticMatches() {
        let selected = entry("Alias A"), other = entry("Alias B")
        let original = Retailer(name: "Old Shop", domain: nil, logo_url: nil, customIconData: Data([1]))
        let target = Retailer(name: "New Shop", domain: nil, logo_url: nil, customIconData: Data([2]))
        let matches = ["alias a": MerchantMatch(retailer: original, isOverride: true),
                       "alias b": MerchantMatch(retailer: original, isOverride: true),
                       "unrelated": MerchantMatch(retailer: target)]
        let result = MerchantIconSharing.updating(target, for: selected, entries: [selected, other], matches: matches)
        XCTAssertEqual(result["alias b"], matches["alias b"])
        XCTAssertFalse(result["unrelated"]!.isOverride)
        let icons = MerchantIconSharing.index(matches: result)
        XCTAssertEqual(icons["oldshop"]?.customIconData, Data([1]))
        XCTAssertEqual(icons["newshop"]?.customIconData, Data([2]))
    }
}
