import Foundation

public struct BankAccount: Codable, Identifiable, Sendable {
    public let id: String
    public let name: String
    public let kind: String
    public let currency: String
    public let current: String?
    public let transactionCount: Int
    public init(id: String, name: String, kind: String, currency: String, current: String?, transactionCount: Int) {
        self.id = id; self.name = name; self.kind = kind; self.currency = currency
        self.current = current; self.transactionCount = transactionCount
    }

    public var currentBalance: Decimal? {
        guard let current,
              current.range(of: #"^[+-]?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: current, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN else { return nil }
        return value
    }

    /// TrueLayer reports card expenditure as positive; debt reduces our balance.
    /// Preserve the sign so an overpaid card contributes a positive credit.
    public var netBalance: Decimal? {
        currentBalance.map { kind == "cards" ? -$0 : $0 }
    }
}

/// Bank balances less card debt, in a single currency. A missing balance must
/// not produce a misleading partial sum.
public struct BankBalanceSummary: Sendable {
    public let accountCount: Int
    public let total: Decimal?
    /// `importedBalance`, when supplied, must already be signed and in `currency`.
    public init(accounts: [BankAccount], currency: String, importedBalance: Decimal? = nil) {
        let included = accounts.filter {
            ["accounts", "cards"].contains($0.kind) && $0.currency.uppercased() == currency.uppercased()
        }
        accountCount = included.count + (importedBalance == nil ? 0 : 1)
        let balances = included.compactMap(\.netBalance) + [importedBalance].compactMap { $0 }
        total = accountCount > 0 && balances.count == accountCount ? balances.reduce(0, +) : nil
    }
}

public enum BudgetCurrency {
    public static func detected(accounts: [BankAccount], entries: [Entry]) -> [String] {
        Set((accounts.map(\.currency) + entries.map(\.currency))
            .map { $0.uppercased() }.filter { !$0.isEmpty }).sorted()
    }

    public static func selected(_ preference: String?, available: [String]) -> String {
        if let preference, available.contains(preference) { return preference }
        return available.contains("GBP") ? "GBP" : available.first ?? "GBP"
    }
}

public enum ImportedAccountBalance {
    /// Nets this calendar month's imports through `asOf`, with no balance carried forward.
    /// Repayments and refunds count even when categorised as transfers or income.
    public static func balance(entries: [Entry], account: String, currency: String, asOf: Date = Date(),
                               calendar: Calendar = .current) -> Decimal? {
        let included = entries.filter {
            ($0.id.hasPrefix("csv:") || $0.id.hasPrefix("yonder:")) &&
            $0.account == account && $0.currency.uppercased() == currency.uppercased() && $0.date <= asOf
        }
        guard !included.isEmpty else { return nil }
        guard let monthStart = calendar.dateInterval(of: .month, for: asOf)?.start else { return nil }
        return included.filter { $0.date >= monthStart }.reduce(Decimal.zero) { $0 + $1.amount }
    }
}

public struct BankSync: Decodable, Sendable {
    public let providerID: String
    public let syncedAt: String
    public let accounts: [BankAccount]
    public let warnings: [String]
    public let windows: [Window]
    public init(providerID: String, syncedAt: String, accounts: [BankAccount], warnings: [String], windows: [Window]) {
        self.providerID = providerID; self.syncedAt = syncedAt; self.accounts = accounts; self.warnings = warnings; self.windows = windows
    }
    public struct Window: Decodable, Sendable {
        public let prefix: String
        public let from: String
        public let to: String
        public let entries: [Transaction]
        /// Complete pending snapshot, independent of the settled date window. Nil leaves it unchanged.
        public let pendingEntries: [Transaction]?
        public init(prefix: String, from: String, to: String, entries: [Transaction], pendingEntries: [Transaction]? = nil) {
            self.prefix = prefix; self.from = from; self.to = to; self.entries = entries
            self.pendingEntries = pendingEntries
        }
    }

    /// A focused diagnostic: no tokens or internal transaction/account IDs.
    public func transactionReport(query: String, saved: [Entry]) -> String {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let amountText = text.replacingOccurrences(of: "£", with: "").replacingOccurrences(of: ",", with: "")
        let amount = amountText.range(of: #"^-?[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil
            ? Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX")) : nil
        func matches(_ entry: Entry) -> Bool {
            entry.description.localizedCaseInsensitiveContains(text)
                || entry.merchant.localizedCaseInsensitiveContains(text)
                || amount.map { entry.magnitude == ($0 < 0 ? -$0 : $0) } == true
        }
        func describe(_ entry: Entry) -> String {
            "\(entry.date.formatted(.iso8601.year().month().day().dateSeparator(.dash))) · \(entry.amount) \(entry.currency)\n\(entry.description)\n\(entry.account)"
        }
        var lines = ["Checked: \(syncedAt)", "Search: \(text)", "Returned accounts/cards: \(windows.count)"]
        for window in windows {
            lines.append("\n\(accounts.first(where: { $0.id == window.prefix })?.name ?? "Account")")
            lines.append("Requested: \(window.from) to \(window.to)")
            for (label, rows) in [("Settled response", window.entries), ("Pending response", window.pendingEntries ?? [])] {
                let found = rows.compactMap { try? $0.entry() }.filter(matches)
                lines.append("\(label): \(rows.count) returned, \(found.count) matches")
                lines.append(contentsOf: found.map(describe))
            }
        }
        let local = saved.filter { $0.providerID == providerID && matches($0) }
        lines.append("\nSaved in Budget: \(local.count) matches")
        lines.append(contentsOf: local.map { "\($0.isPending ? "Pending" : "Settled"): \(describe($0))" })
        lines.append("\nDiagnostic only. Saved transactions were not changed.")
        return lines.joined(separator: "\n")
    }
    public struct Transaction: Decodable, Sendable {
        public let id: String
        public let timestamp: String
        public let description: String
        public let amount: String
        public let currency: String
        public let account: String
        public let providerID: String
        public let merchantName: String?
        public let classification: [String]
        public let transactionCategory: String

        public init(id: String, timestamp: String, description: String, amount: String, currency: String,
                    account: String, providerID: String, merchantName: String?, classification: [String], transactionCategory: String) {
            self.id = id; self.timestamp = timestamp; self.description = description; self.amount = amount
            self.currency = currency; self.account = account; self.providerID = providerID
            self.merchantName = merchantName; self.classification = classification; self.transactionCategory = transactionCategory
        }
        public func entry() throws -> Entry {
            guard let value = Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX")),
                  !value.isNaN else { throw CSVError.invalid("Invalid bank transaction amount.") }
            let category: Category
            let labels = classification.map { $0.lowercased() }
            if transactionCategory == "TRANSFER" {
                category = .transfer
            } else if labels.contains("groceries") { category = .groceries }
            else if labels.contains("eating out") || labels.contains("dining") { category = .dining }
            else if labels.contains("transport") || labels.contains("travel") { category = .travel }
            else if labels.contains("entertainment") { category = .entertainment }
            else if labels.contains("shopping") { category = .shopping }
            else if labels.contains("bills and utilities") || labels.contains("bills") { category = .bills }
            else { category = value > 0 ? .income : .other }
            return Entry(id: id, date: try BankSync.date(timestamp), description: description,
                amount: value, currency: currency, account: account, category: category,
                providerID: providerID, merchantName: merchantName)
        }
    }

    public static func date(_ value: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        if let date = formatter.date(from: value) { return date }
        // Some providers omit the timezone. Interpret these provider timestamps in UTC.
        if let date = formatter.date(from: value + "Z") { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value + "Z") { return date }
        throw CSVError.invalid("Invalid bank transaction date.")
    }

    /// Category labels and counts only; excludes all identifying transaction fields.
    public var categoryReport: String {
        let rows = windows.flatMap(\.entries).filter { Decimal(string: $0.amount) != 0 }
        let classified = rows.filter { !$0.classification.isEmpty }
        let labels = Dictionary(grouping: classified, by: { $0.classification.joined(separator: " → ") })
        let types = Dictionary(grouping: rows, by: \.transactionCategory)
        var lines = ["Bank category summary", "Non-zero transactions: \(rows.count)",
                     "With spending classifications: \(classified.count)",
                     "Without spending classifications: \(rows.count - classified.count)", "", "Spending classifications"]
        if labels.isEmpty { lines.append("None returned") }
        for label in labels.keys.sorted() { lines.append("\(label): \(labels[label]!.count)") }
        lines += ["", "Transaction types"]
        for type in types.keys.sorted() { lines.append("\(type.isEmpty ? "Not supplied" : type): \(types[type]!.count)") }
        return lines.joined(separator: "\n")
    }

    /// Update stable booked records, retaining them across provider omissions.
    /// Replace request-ID windows because those identifiers can change per fetch.
    public func merging(into existing: [Entry], rules: [String: Category]) throws -> [Entry] {
        var result = existing
        var prefixes = Set<String>()
        for window in windows {
            guard window.prefix.hasPrefix("truelayer:\(providerID):"), prefixes.insert(window.prefix).inserted else {
                throw CSVError.invalid("Invalid bank sync window.")
            }
            let start = try Self.date(window.from), end = try Self.date(window.to)
            guard start <= end else { throw CSVError.invalid("Invalid bank sync dates.") }
            let incoming = try window.entries.map { try $0.entry() }
            guard Set(incoming.map(\.id)).count == incoming.count,
                  incoming.allSatisfy({ $0.providerID == providerID && $0.id.hasPrefix(window.prefix) && $0.date >= start && $0.date <= end }) else {
                throw CSVError.invalid("Invalid or duplicate bank transactions. Nothing was saved.")
            }
            let previous = result.filter { $0.id.hasPrefix(window.prefix) && !$0.isPending }
            let byID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
            let incomingIDs = Set(incoming.map(\.id))
            // For changing request IDs, carry edits across only unambiguous matches.
            func fingerprint(_ entry: Entry) -> String {
                "\(entry.date.timeIntervalSince1970)|\(entry.amount)|\(entry.currency)|\(entry.description)|\(entry.merchantKey)"
            }
            let previousPending = result.filter { $0.isPending && $0.id.hasPrefix(window.prefix) }
            let pendingByID = Dictionary(uniqueKeysWithValues: previousPending.map { ($0.id, $0) })
            let pendingGroups = Dictionary(grouping: previousPending, by: fingerprint)
            let fetchedPending = try window.pendingEntries?.map { try $0.entry() } ?? []
            let freshGroups = Dictionary(grouping: incoming + fetchedPending, by: fingerprint)
            func pendingCategory(for entry: Entry) -> Category? {
                if let same = pendingByID[entry.id] { return same.categoryOverride }
                let suffix = String(entry.id.dropFirst(window.prefix.count))
                if suffix.hasPrefix("stable:"), let same = pendingByID[window.prefix + "pending:" + suffix] {
                    return same.categoryOverride
                }
                let key = fingerprint(entry)
                guard pendingGroups[key]?.count == 1, freshGroups[key]?.count == 1 else { return nil }
                return pendingGroups[key]?.first?.categoryOverride
            }
            let unmatched = previous.filter { !incomingIDs.contains($0.id) && $0.id.hasPrefix(window.prefix + "request:") && $0.date >= start && $0.date <= end }
            let oldGroups = Dictionary(grouping: unmatched, by: fingerprint)
            let newGroups = Dictionary(grouping: incoming.filter { byID[$0.id] == nil }, by: fingerprint)
            let replacements = incoming.map { incoming -> Entry in
                var entry = incoming
                let key = fingerprint(entry)
                let old = byID[entry.id] ?? (oldGroups[key]?.count == 1 && newGroups[key]?.count == 1 ? oldGroups[key]?.first : nil)
                if let old {
                    entry.notes = old.notes
                    entry.reimbursement = old.reimbursement
                    entry.recurringMonthly = old.recurringMonthly
                    entry.categoryOverride = old.categoryOverride
                    // Existing manual categorisation survives provider reclassification.
                    entry.category = old.category
                } else {
                    entry.categoryOverride = pendingCategory(for: entry)
                }
                return Categorisation.apply(to: entry, rules: rules)
            }
            result.removeAll {
                guard !$0.isPending, $0.id.hasPrefix(window.prefix) else { return false }
                if incomingIDs.contains($0.id) { return true }
                // Absence is not proof that a booked payment was cancelled.
                // Stable IDs let us retain it safely and update it on a later sync.
                if $0.id.hasPrefix(window.prefix + "stable:") { return false }
                return $0.date >= start && $0.date <= end
            }
            result.append(contentsOf: replacements)
            if let pendingRows = window.pendingEntries {
                let pending = try pendingRows.map { try $0.entry() }
                guard Set(pending.map(\.id)).count == pending.count,
                      pending.allSatisfy({ $0.providerID == providerID && $0.id.hasPrefix(window.prefix + "pending:") }) else {
                    throw CSVError.invalid("Invalid or duplicate pending transactions. Nothing was saved.")
                }
                // Pending authorisations can disappear or settle under entirely different IDs,
                // dates and amounts. Replace the snapshot, never archive missing authorisations.
                result.removeAll { $0.isPending && $0.id.hasPrefix(window.prefix) }
                let settledIDs = Set(result.filter { !$0.isPending }.map(\.id))
                for var entry in pending {
                    let suffix = String(entry.id.dropFirst((window.prefix + "pending:").count))
                    // Only explicit stable IDs establish identity across the two endpoints.
                    if suffix.hasPrefix("stable:"), settledIDs.contains(window.prefix + suffix) { continue }
                    entry.pending = true
                    entry.categoryOverride = pendingCategory(for: entry)
                    result.append(Categorisation.apply(to: entry, rules: rules))
                }
            }
        }
        return result.sorted { $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date }
    }
}


public enum BankSyncSchedule {
    public static func isDue(lastSuccess: Date?, lastAutomaticAttempt: Date?, now: Date = Date()) -> Bool {
        if let lastSuccess, now.timeIntervalSince(lastSuccess) < 6 * 60 * 60 { return false }
        // Avoid repeatedly retrying a failed bank whenever the app becomes active.
        if let lastAutomaticAttempt, now.timeIntervalSince(lastAutomaticAttempt) < 15 * 60 { return false }
        return true
    }
}

/// Fictional, deterministic data for the developer demo. Never loaded from a bank.
public struct DemoDataset {
    public let entries: [Entry]
    public let budgets: [String: Decimal]
    public let providers: [BankProvider]
    public let accounts: [String: [BankAccount]]

    public init(now: Date = Date(), calendar: Calendar = .current) {
        providers = [("ob-barclays", "Barclays"), ("ob-natwest", "NatWest"), ("ob-amex", "American Express")].map {
            BankProvider(id: $0.0, name: $0.1, country: "uk", logoURL: nil,
                         scopes: ["accounts", "cards", "balance", "transactions", "offline_access"], availability: nil)
        }
        budgets = ["Groceries": 350, "Dining": 200, "Travel": 150, "Shopping": 180,
                   "Bills": 1000, "Health & Beauty": 80, "Entertainment": 100, "Other": 100]
        let rows: [(String, Decimal, Category)] = [
            ("Salary", 3400, .income), ("Rent", -850, .bills),
            ("Waitrose", -54.20, .groceries), ("Neighbourhood Coffee", -8.50, .dining),
            ("Transport for London", -12.80, .travel), ("Uniqlo", -64.90, .shopping),
            ("Boots", -23.40, .healthAndBeauty), ("Cinema", -28, .entertainment),
            ("Sainsbury’s", -71.35, .groceries), ("Pizza Night", -46, .dining),
            ("Work lunch", -24, .dining), ("Savings transfer", -250, .savings)
        ]
        let currentMonth = calendar.dateInterval(of: .month, for: now)!.start
        var generated: [Entry] = []
        for offset in 0..<3 {
            let month = calendar.date(byAdding: .month, value: -offset, to: currentMonth)!
            for (index, row) in rows.enumerated() {
                let day = offset == 0 ? min(index * 2, calendar.component(.day, from: now) - 1) : index * 2
                let date = calendar.date(byAdding: .day, value: day, to: month)!
                let isCard = index >= 4 && index % 2 == 0
                let isYonder = index == 9
                let bank = isCard ? "ob-amex" : (index == 11 ? "ob-natwest" : "ob-barclays")
                let account = isYonder ? "Yonder" : (isCard ? "American Express · Gold Card" : (bank == "ob-natwest" ? "NatWest · Current Account" : "Barclays · Current Account"))
                let prefix = isYonder ? "yonder:demo:" : "truelayer:\(bank):\(isCard ? "cards" : "accounts"):demo:"
                var entry = Entry(id: "\(prefix)\(offset)-\(index)", date: date, description: row.0,
                                  amount: row.1, account: account, category: row.2,
                                  providerID: isYonder ? nil : bank)
                if index == 10 { entry.reimbursement = 18 }
                if offset == 0 && index == 5 { entry.pending = true }
                generated.append(entry)
            }
        }
        entries = generated
        var balances: [String: [BankAccount]] = [:]
        for (id, name, kind, balance) in [
            ("ob-barclays", "Barclays · Current Account", "accounts", "2450.65"),
            ("ob-natwest", "NatWest · Current Account", "accounts", "1200.00"),
            ("ob-amex", "American Express · Gold Card", "cards", "486.35")
        ] {
            let prefix = "truelayer:\(id):\(kind):demo:"
            balances[id] = [BankAccount(id: prefix, name: name, kind: kind, currency: "GBP", current: balance,
                                       transactionCount: generated.filter { $0.id.hasPrefix(prefix) }.count)]
        }
        accounts = balances
    }
}
