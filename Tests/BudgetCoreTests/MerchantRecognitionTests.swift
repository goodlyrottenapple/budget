import Foundation
import XCTest
@testable import BudgetCore

final class MerchantRecognitionTests: XCTestCase {
    func testLegacyRetailerMetadataStillDecodesWithoutCustomIcon() throws {
        let json = #"{"name":"Shop","domain":"shop.com","logo_url":"https://img.logo.dev/shop.com"}"#
        let retailer = try JSONDecoder().decode(Retailer.self, from: Data(json.utf8))
        XCTAssertNil(retailer.customIconData)
        XCTAssertEqual(retailer.logoURL?.host, "img.logo.dev")
    }

    func testCustomMerchantDoesNotNeedADomainAndPreservesOriginalDetails() throws {
        let entry = Entry(id: "local", date: Date(), description: "SQ* LOCAL SHOP 123", amount: -5, account: "Yonder")
        let retailer = Retailer(name: "My local shop", domain: nil, logo_url: nil, customIconData: Data([1, 2, 3]))
        let match = MerchantMatch(retailer: retailer, isOverride: true)
        let reopened = try JSONDecoder().decode(MerchantMatch.self, from: JSONEncoder().encode(match))
        XCTAssertEqual(reopened.displayName(for: entry), "My local shop")
        XCTAssertEqual(reopened.retailer?.customIconData, retailer.customIconData)
        XCTAssertTrue(reopened.isOverride)
        XCTAssertEqual(entry.description, "SQ* LOCAL SHOP 123")
        var withRemoteLogo = retailer
        withRemoteLogo.logo_url = "https://img.logo.dev/shop.com"
        XCTAssertNil(withRemoteLogo.logoURL, "A custom image must not trigger a network logo request")
    }

    func testFuzzyMatchingAcceptsSmallTyposAndFormatting() {
        let retailer = Retailer(name: "Sainsbury's", domain: "sainsburys.co.uk", logo_url: nil)
        XCTAssertEqual(MerchantRecognition.automaticMatch(for: "SAINSBURYS LTD", candidates: [retailer]), retailer)
        XCTAssertEqual(MerchantRecognition.automaticMatch(for: "SAINSBURYS", candidates: [
            Retailer(name: "Sainsburysx", domain: "sainsburys.co.uk", logo_url: nil)
        ])?.domain, "sainsburys.co.uk")
        XCTAssertEqual(MerchantRecognition.similarity(merchant: "Café Nero", retailer: "Cafe Nero"), 1)
    }
    func testFuzzyMatchingRejectsWeakShortAndAmbiguousMatches() {
        let apple = Retailer(name: "Apple", domain: "apple.com", logo_url: nil)
        XCTAssertNil(MerchantRecognition.automaticMatch(for: "APPLE TREE CAFE", candidates: [apple]))
        XCTAssertEqual(MerchantRecognition.similarity(merchant: "ALDI", retailer: "ALDO"), 0)
        XCTAssertNil(MerchantRecognition.automaticMatch(for: "123456", candidates: [apple]))
        let shops = [Retailer(name: "Coffee Shop", domain: "one.co.uk", logo_url: nil),
                     Retailer(name: "Coffee Shop", domain: "two.co.uk", logo_url: nil)]
        XCTAssertNil(MerchantRecognition.automaticMatch(for: "COFFEE SHOP", candidates: shops))
        XCTAssertEqual(MerchantRecognition.automaticMatch(for: "APPLE", candidates: [apple, apple]), apple)
    }
    func testFuzzyMatchingRanksCandidatesInsteadOfUsingFirstResult() {
        let wrong = Retailer(name: "Amazonas", domain: "amazonas.com", logo_url: nil)
        let right = Retailer(name: "Amazon", domain: "amazon.co.uk", logo_url: nil)
        XCTAssertEqual(MerchantRecognition.automaticMatch(for: "AMAZON", candidates: [wrong, right]), right)
    }
    func testSearchCleansProcessorPrefixesAndReferenceNumbers() {
        XCTAssertEqual(MerchantRecognition.queries(for: "SQ* COFFEE SHOP 1234 LONDON"),
            ["COFFEE SHOP LONDON", "COFFEE SHOP", "COFFEE"])
        XCTAssertEqual(MerchantRecognition.queries(for: "7-Eleven"), ["7-Eleven"])
        XCTAssertEqual(MerchantRecognition.queries(for: "B&Q"), ["B&Q"])
        XCTAssertTrue(MerchantRecognition.queries(for: "123456").isEmpty)
    }
    func testRetailerMetadataDoesNotChangeOriginalMerchantKeysOrCategoryRules() throws {
        let entry = Entry(id: "one", date: Date(), description: "SQ* SHOP 1234", amount: -5, account: "Amex")
        let retailer = Retailer(name: "Shop", domain: "shop.com", logo_url: nil)
        let matches = [entry.merchantKey: MerchantMatch(retailer: retailer, isOverride: true)]
        let future = Entry(id: "two", date: Date(), description: "sq* shop 1234", amount: -10, account: "Other bank")
        XCTAssertEqual(matches[future.merchantKey]?.retailer, retailer)
        XCTAssertEqual(entry.description, "SQ* SHOP 1234")
        XCTAssertEqual(Categorisation.apply(to: future, rules: [entry.merchantKey: .house]).category, .house)
        let encoded = try JSONEncoder().encode(matches)
        XCTAssertEqual(try JSONDecoder().decode([String: MerchantMatch].self, from: encoded), matches)
    }
    func testOriginalNameOverrideRemovesRetailerAndPreservesRawDescription() throws {
        let entry = Entry(id: "local", date: Date(), description: "LOCAL SHOP ORIGINAL", amount: -5,
            account: "Amex", merchantName: "Local shop")
        let match = MerchantMatch(retailer: nil, isOverride: true)
        XCTAssertEqual(match.displayName(for: entry), "LOCAL SHOP ORIGINAL")
        XCTAssertNil(match.retailer)
        let roundTrip = try JSONDecoder().decode(MerchantMatch.self, from: JSONEncoder().encode(match))
        XCTAssertTrue(roundTrip.isOverride)
        XCTAssertEqual(roundTrip.displayName(for: entry), entry.description)
    }
    func testOnlyTrustedLogoURLsCanBeDisplayed() {
        XCTAssertNil(Retailer(name: "Shop", domain: "shop.com", logo_url: "https://other.com/logo").logoURL)
        XCTAssertNil(Retailer(name: "Shop", domain: "shop.com", logo_url: "http://img.logo.dev/shop.com").logoURL)
        XCTAssertNil(Retailer(name: "Shop", domain: "shop.com", logo_url: "https://img.logo.dev/shop.com?token=sk_private").logoURL)
        XCTAssertNotNil(Retailer(name: "Shop", domain: "shop.com", logo_url: "https://img.logo.dev/shop.com?token=pk_public").logoURL)
    }
}
