import Foundation
import SwiftData
#if SWIFT_PACKAGE
import BudgetCore
public typealias StoredCategory = BudgetCore.Category
#else
public typealias StoredCategory = Category
#endif

public enum BudgetModels {
    public static var schema: Schema {
        Schema([Transaction.self, Budget.self, MerchantRule.self, Source.self, Settings.self, RetailerMatch.self, RetailerSearch.self])
    }

    @Model public final class Transaction {
        @Attribute(.unique) public var id: String
        public var date: Date
        public var details: String
        public var amount: String
        public var currency: String
        public var account: String
        public var category: String
        public var categoryOverride: String?
        public var merchantName: String?
        public var providerID: String?
        public var notes: String?
        public var reimbursement: String?
        public var pending: Bool?
        public var recurringMonthly: Bool?
        public init(entry: Entry) {
            id = entry.id; date = entry.date; details = entry.description
            amount = NSDecimalNumber(decimal: entry.amount).stringValue
            currency = entry.currency; account = entry.account; category = entry.category.rawValue
            categoryOverride = entry.categoryOverride?.rawValue
            merchantName = entry.merchantName; providerID = entry.providerID
            pending = entry.pending
            recurringMonthly = entry.recurringMonthly
            notes = entry.notes
            reimbursement = entry.reimbursement.map { NSDecimalNumber(decimal: $0).stringValue }
        }
        public func update(_ entry: Entry) {
            date = entry.date; details = entry.description
            amount = NSDecimalNumber(decimal: entry.amount).stringValue
            currency = entry.currency; account = entry.account; category = entry.category.rawValue
            categoryOverride = entry.categoryOverride?.rawValue
            merchantName = entry.merchantName; providerID = entry.providerID
            pending = entry.pending
            recurringMonthly = entry.recurringMonthly
            notes = entry.notes
            reimbursement = entry.reimbursement.map { NSDecimalNumber(decimal: $0).stringValue }
        }
        public func entry() throws -> Entry {
            guard let decimal = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")) else { throw PersistenceError.invalidData }
            var entry = Entry(id: id, date: date, description: details, amount: decimal,
                              currency: currency, account: account, category: try decodeStoredCategory(category),
                              providerID: providerID, merchantName: merchantName)
            entry.categoryOverride = try categoryOverride.map(decodeStoredCategory)
            entry.pending = pending
            entry.recurringMonthly = recurringMonthly
            entry.notes = notes
            if let reimbursement {
                guard let value = Decimal(string: reimbursement, locale: Locale(identifier: "en_US_POSIX")),
                      !value.isNaN, value >= 0 else { throw PersistenceError.invalidData }
                entry.reimbursement = value
            }
            return entry
        }
    }
    @Model public final class Budget {
        @Attribute(.unique) public var category: String
        public var amount: String
        public init(category: String, amount: Decimal) {
            self.category = category; self.amount = NSDecimalNumber(decimal: amount).stringValue
        }
    }
    @Model public final class MerchantRule {
        @Attribute(.unique) public var merchantKey: String
        public var category: String
        public init(key: String, category: String) { merchantKey = key; self.category = category }
    }
    @Model public final class RetailerSearch {
        @Attribute(.unique) public var query: String
        public var results: Data
        public init(query: String, results: Data) { self.query = query; self.results = results }
    }
    @Model public final class RetailerMatch {
        @Attribute(.unique) public var merchantKey: String
        public var metadata: Data
        public init(key: String, metadata: Data) { merchantKey = key; self.metadata = metadata }
    }
    @Model public final class Source {
        @Attribute(.unique) public var providerID: String
        public var metadata: Data
        public init(id: String, metadata: Data) { providerID = id; self.metadata = metadata }
    }
    @Model public final class Settings {
        @Attribute(.unique) public var id: String
        public var isDemo: Bool
        public var budgetCurrency: String? = nil
        public init(isDemo: Bool, budgetCurrency: String? = nil) {
            id = "app"; self.isDemo = isDemo; self.budgetCurrency = budgetCurrency
        }
    }
}

public enum PersistenceError: Error { case invalidData, duplicateTransactionID }

private func decodeStoredCategory(_ value: String) throws -> StoredCategory {
    guard let category = StoredCategory(rawValue: value == "Workshop" ? "Other" : value) else { throw PersistenceError.invalidData }
    return category
}

/// Value state used by the UI; persisted as separate SwiftData records.
public struct BudgetSnapshot {
    public var budgetCurrency: String?
    public var entries: [Entry]
    public var budgets: [String: Decimal]
    public var isDemo: Bool
    public var sources: [BankProvider]
    public var merchantMatches: [String: MerchantMatch]
    public var merchantRules: [String: StoredCategory]
    public init(entries: [Entry], budgets: [String: Decimal], isDemo: Bool,
                sources: [BankProvider] = [], merchantRules: [String: StoredCategory] = [:], merchantMatches: [String: MerchantMatch] = [:], budgetCurrency: String? = nil) {
        self.entries = entries; self.budgets = budgets; self.isDemo = isDemo
        self.budgetCurrency = budgetCurrency
        self.sources = sources; self.merchantRules = merchantRules; self.merchantMatches = merchantMatches
    }
}

@MainActor
public final class BudgetRepository {
    public let container: ModelContainer
    private let context: ModelContext

    public init(storeURL: URL) throws {
        let directory = storeURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #if os(iOS)
        let protection: [FileAttributeKey: Any] = [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        try FileManager.default.setAttributes(protection, ofItemAtPath: directory.path)
        for path in [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes(protection, ofItemAtPath: path)
        }
        #endif
        let schema = BudgetModels.schema
        let configuration = ModelConfiguration("Budget", schema: schema, url: storeURL, cloudKitDatabase: .none)
        container = try ModelContainer(for: schema, configurations: [configuration])
        #if os(iOS)
        for path in [storeURL.path, storeURL.path + "-wal", storeURL.path + "-shm"] where FileManager.default.fileExists(atPath: path) {
            try FileManager.default.setAttributes(protection, ofItemAtPath: path)
        }
        #endif
        context = ModelContext(container)
        context.autosaveEnabled = false
    }

    public func load() throws -> BudgetSnapshot? {
        guard let settings = try context.fetch(FetchDescriptor<BudgetModels.Settings>()).first else { return nil }
        let entries = try context.fetch(FetchDescriptor<BudgetModels.Transaction>()).map { try $0.entry() }.sorted { $0.date > $1.date }
        var budgets: [String: Decimal] = [:]
        for record in try context.fetch(FetchDescriptor<BudgetModels.Budget>()) {
            guard let amount = Decimal(string: record.amount, locale: Locale(identifier: "en_US_POSIX")) else { throw PersistenceError.invalidData }
            budgets[record.category] = amount
        }
        let sources = try context.fetch(FetchDescriptor<BudgetModels.Source>()).map { try JSONDecoder().decode(BankProvider.self, from: $0.metadata) }
        var rules: [String: StoredCategory] = [:]
        for record in try context.fetch(FetchDescriptor<BudgetModels.MerchantRule>()) { rules[record.merchantKey] = try decodeStoredCategory(record.category) }
        var matches: [String: MerchantMatch] = [:]
        for record in try context.fetch(FetchDescriptor<BudgetModels.RetailerMatch>()) {
            matches[record.merchantKey] = try JSONDecoder().decode(MerchantMatch.self, from: record.metadata)
        }
        return BudgetSnapshot(entries: entries, budgets: budgets, isDemo: settings.isDemo, sources: sources, merchantRules: rules, merchantMatches: matches, budgetCurrency: settings.budgetCurrency)
    }

    public func cachedRetailers(for query: String) throws -> [Retailer]? {
        let key = Categorisation.merchantKey(query)
        let descriptor = FetchDescriptor<BudgetModels.RetailerSearch>(predicate: #Predicate { $0.query == key })
        guard let record = try context.fetch(descriptor).first else { return nil }
        return try JSONDecoder().decode([Retailer].self, from: record.results)
    }

    public func cacheRetailers(_ retailers: [Retailer], for query: String) throws {
        do {
            let key = Categorisation.merchantKey(query)
            let data = try JSONEncoder().encode(retailers)
            let descriptor = FetchDescriptor<BudgetModels.RetailerSearch>(predicate: #Predicate { $0.query == key })
            if let record = try context.fetch(descriptor).first { record.results = data }
            else { context.insert(BudgetModels.RetailerSearch(query: key, results: data)) }
            try context.save()
        } catch { context.rollback(); throw error }
    }

    public func save(_ snapshot: BudgetSnapshot) throws {
        guard Set(snapshot.entries.map(\.id)).count == snapshot.entries.count else { throw PersistenceError.duplicateTransactionID }
        do {
            let transactions = try context.fetch(FetchDescriptor<BudgetModels.Transaction>())
            let existing = Dictionary(uniqueKeysWithValues: transactions.map { ($0.id, $0) })
            let ids = Set(snapshot.entries.map(\.id))
            for record in transactions where !ids.contains(record.id) { context.delete(record) }
            for entry in snapshot.entries {
                if let record = existing[entry.id] { record.update(entry) }
                else { context.insert(BudgetModels.Transaction(entry: entry)) }
            }
            let budgets = try context.fetch(FetchDescriptor<BudgetModels.Budget>())
            let budgetMap = Dictionary(uniqueKeysWithValues: budgets.map { ($0.category, $0) })
            for record in budgets where snapshot.budgets[record.category] == nil { context.delete(record) }
            for (category, amount) in snapshot.budgets {
                if let record = budgetMap[category] { record.amount = NSDecimalNumber(decimal: amount).stringValue }
                else { context.insert(BudgetModels.Budget(category: category, amount: amount)) }
            }
            let rules = snapshot.merchantRules
            let storedRules = try context.fetch(FetchDescriptor<BudgetModels.MerchantRule>())
            let ruleMap = Dictionary(uniqueKeysWithValues: storedRules.map { ($0.merchantKey, $0) })
            for record in storedRules where rules[record.merchantKey] == nil { context.delete(record) }
            for (key, category) in rules {
                if let record = ruleMap[key] { record.category = category.rawValue }
                else { context.insert(BudgetModels.MerchantRule(key: key, category: category.rawValue)) }
            }
            let storedMatches = try context.fetch(FetchDescriptor<BudgetModels.RetailerMatch>())
            let matchMap = Dictionary(uniqueKeysWithValues: storedMatches.map { ($0.merchantKey, $0) })
            for record in storedMatches where snapshot.merchantMatches[record.merchantKey] == nil { context.delete(record) }
            for (key, match) in snapshot.merchantMatches {
                let metadata = try JSONEncoder().encode(match)
                if let record = matchMap[key] { record.metadata = metadata }
                else { context.insert(BudgetModels.RetailerMatch(key: key, metadata: metadata)) }
            }
            let sources = snapshot.sources
            let storedSources = try context.fetch(FetchDescriptor<BudgetModels.Source>())
            let sourceMap = Dictionary(uniqueKeysWithValues: storedSources.map { ($0.providerID, $0) })
            let sourceIDs = Set(sources.map(\.id))
            for record in storedSources where !sourceIDs.contains(record.providerID) { context.delete(record) }
            for source in sources {
                let metadata = try JSONEncoder().encode(source)
                if let record = sourceMap[source.id] { record.metadata = metadata }
                else { context.insert(BudgetModels.Source(id: source.id, metadata: metadata)) }
            }
            if let settings = try context.fetch(FetchDescriptor<BudgetModels.Settings>()).first {
                settings.isDemo = snapshot.isDemo
                settings.budgetCurrency = snapshot.budgetCurrency
            } else { context.insert(BudgetModels.Settings(isDemo: snapshot.isDemo, budgetCurrency: snapshot.budgetCurrency)) }
            try context.save()
        } catch {
            context.rollback()
            throw error
        }
    }
}
