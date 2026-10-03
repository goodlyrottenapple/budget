import Foundation

public enum Category: String, Codable, CaseIterable, Sendable {
    case groceries = "Groceries", dining = "Dining", travel = "Travel"
    case entertainment = "Entertainment"
    case shopping = "Shopping", bills = "Bills", other = "Other"
    case house = "House"
    case healthAndBeauty = "Health & Beauty"
    case savings = "Savings"
    case income = "Income", transfer = "Transfer"

    public static var spending: [Category] { [.groceries, .dining, .travel, .entertainment, .shopping, .healthAndBeauty, .bills, .house, .other] }
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let stored = try container.decode(String.self)
        guard let category = Category(rawValue: stored == "Transport" ? "Travel" : stored == "Workshop" ? "Other" : stored) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown category")
        }
        self = category
    }
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    public var symbol: String {
        switch self {
        case .groceries: "basket"
        case .dining: "fork.knife"
        case .travel: "airplane"
        case .entertainment: "theatermasks"
        case .shopping: "bag"
        case .bills: "creditcard"
        case .house: "house"
        case .healthAndBeauty: "heart"
        case .savings: "banknote"
        case .other: "ellipsis"
        case .income: "arrow.down.left"
        case .transfer: "arrow.left.arrow.right"
        }
    }
}

public struct Entry: Identifiable, Codable, Sendable {
    public var id: String
    public var date: Date
    public var description: String
    /// Positive amounts are money received; negative amounts are money spent.
    public var amount: Decimal
    public var currency: String
    public var account: String
    public var category: Category
    public var providerID: String?
    public var merchantName: String?
    public var categoryOverride: Category?
    public var notes: String?
    public var reimbursement: Decimal?
    public var pending: Bool?
    public var recurringMonthly: Bool?
    public var isPending: Bool { pending == true }
    public var reimbursedAmount: Decimal {
        guard amount < 0, let reimbursement, !reimbursement.isNaN else { return 0 }
        return min(magnitude, max(0, reimbursement))
    }
    public var reimbursementStatus: String? {
        guard reimbursedAmount > 0 else { return nil }
        return reimbursedAmount == magnitude ? "Reimbursed" : "Partially reimbursed"
    }

    public func validatedReimbursement(_ text: String, locale: Locale = .current) throws -> Decimal {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        if value.isEmpty { return 0 }
        guard value.range(of: #"^(?:[0-9]+(?:\.[0-9]{0,2})?|\.[0-9]{1,2})$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")),
              !amount.isNaN, amount >= 0, amount <= (self.amount < 0 ? magnitude : 0) else {
            throw CSVError.invalid("Enter an amount from zero to the transaction amount, with up to two decimal places.")
        }
        return amount
    }
    public var merchant: String { merchantName?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? merchantName! : description }
    public var merchantKey: String { Categorisation.merchantKey(merchant) }
    public var bankAccountKind: String? {
        let parts = id.split(separator: ":")
        guard parts.count >= 5, parts[0] == "truelayer", ["accounts", "cards"].contains(parts[2]) else { return nil }
        return String(parts[2])
    }
    public var magnitude: Decimal { amount < 0 ? -amount : amount }

    public init(id: String, date: Date, description: String, amount: Decimal,
                currency: String = "GBP", account: String, category: Category = .other, providerID: String? = nil, merchantName: String? = nil) {
        self.id = id; self.date = date; self.description = description
        self.amount = amount; self.currency = currency; self.account = account; self.category = category
        self.providerID = providerID
        self.merchantName = merchantName
    }
}

public struct TransactionDay: Identifiable, Sendable {
    public var date: Date
    public var entries: [Entry]
    public var id: Date { date }
}

public enum TransactionGrouping {
    public static func days(_ entries: [Entry], calendar: Calendar = .current) -> [TransactionDay] {
        Dictionary(grouping: entries, by: { calendar.startOfDay(for: $0.date) })
            .map { date, entries in
                TransactionDay(date: date, entries: entries.sorted {
                    $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
                })
            }.sorted { $0.date > $1.date }
    }
}

public enum TransferMatching {
    private struct Key: Hashable {
        let day: Date
        let currency: String
        let amount: Decimal
    }

    /// Derived categories keep original categorisation intact if a counterpart disappears.
    public static func apply(to entries: [Entry], rules: [String: Category] = [:], calendar: Calendar = .current) -> [Entry] {
        let groups = Dictionary(grouping: entries.indices.filter { entries[$0].amount != 0 && !entries[$0].isPending }, by: {
            Key(day: calendar.startOfDay(for: entries[$0].date), currency: entries[$0].currency, amount: entries[$0].magnitude)
        })
        func accountKey(_ entry: Entry) -> String {
            let parts = entry.id.split(separator: ":")
            if parts.first == "truelayer", parts.count >= 5 {
                return parts.prefix(4).joined(separator: ":")
            }
            return "\(entry.providerID ?? "csv"):\(Categorisation.merchantKey(entry.account))"
        }
        func canMatch(_ entry: Entry) -> Bool {
            if let override = entry.categoryOverride, override != .transfer { return false }
            if let rule = rules[entry.merchantKey], rule != .transfer { return false }
            return true
        }
        var result = entries
        for indices in groups.values where indices.count == 2 {
            let first = entries[indices[0]], second = entries[indices[1]]
            guard (first.amount < 0) != (second.amount < 0), accountKey(first) != accountKey(second),
                  canMatch(first), canMatch(second) else { continue }
            result[indices[0]].category = .transfer
            result[indices[1]].category = .transfer
        }
        return result
    }
}

public enum Categorisation {
    public static func merchantKey(_ name: String) -> String {
        name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_GB"))
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    public static func apply(to entry: Entry, rules: [String: Category]) -> Entry {
        var result = entry
        if let override = entry.categoryOverride { result.category = override }
        else if let category = rules[entry.merchantKey] { result.category = category }
        return result
    }

    /// The explicit "all" action replaces existing individual exceptions for
    /// this merchant. Later individual changes can create new exceptions.
    public static func update(_ entries: [Entry], transactionID: String, category: Category,
                              allFromMerchant: Bool, rules: inout [String: Category]) -> [Entry] {
        guard let selected = entries.first(where: { $0.id == transactionID }) else { return entries }
        if allFromMerchant { rules[selected.merchantKey] = category }
        return entries.map { entry in
            var result = entry
            if allFromMerchant && entry.merchantKey == selected.merchantKey {
                result.category = category; result.categoryOverride = nil
            } else if !allFromMerchant && entry.id == selected.id {
                result.category = category; result.categoryOverride = category
            }
            return result
        }
    }
}

public struct BankProvider: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var country: String
    public var logoURL: URL?
    public var brandIconURL: URL? {
        guard let logoURL, logoURL.scheme == "https" else { return nil }
        if logoURL.host == "providers-assets.truelayer.com", logoURL.path.hasSuffix("/logo.svg") {
            return logoURL.deletingLastPathComponent().appendingPathComponent("icon.svg")
        }
        if logoURL.host == "truelayer-provider-assets.s3.amazonaws.com", logoURL.path.contains("/global/logos/") {
            return URL(string: logoURL.absoluteString.replacingOccurrences(of: "/global/logos/", with: "/global/icons/"))
        }
        return nil
    }
    public var scopes: [String]
    public struct Availability: Codable, Equatable, Sendable {
        public var status: String
        enum CodingKeys: String, CodingKey { case status = "recommended_status" }
    }
    public var availability: Availability?
    enum CodingKeys: String, CodingKey {
        case id = "provider_id", name = "display_name", country
        case logoURL = "logo_url", scopes, availability
    }
    public var isUKDataProvider: Bool {
        ["uk", "gb"].contains(country.lowercased()) && id != "mock"
        && !id.lowercased().contains("mock")
        && (scopes.contains("accounts") || scopes.contains("cards"))
        && scopes.contains("transactions")
    }
    public var capabilityDescription: String {
        [scopes.contains("accounts") ? "Accounts" : nil, scopes.contains("cards") ? "Cards" : nil]
            .compactMap { $0 }.joined(separator: " · ")
    }
    /// Data API account payloads may omit the catalogue's access-method prefix
    /// (`ob-lloyds` versus `lloyds`). Business variants remain distinct.
    public func matchesAccountProviderID(_ accountProviderID: String?) -> Bool {
        guard let accountProviderID else { return false }
        func canonical(_ input: String) -> String {
            var value = input.lowercased()
            var removedPrefix = true
            while removedPrefix {
                removedPrefix = false
                for prefix in ["uk-", "gb-", "ob-", "oauth-"] where value.hasPrefix(prefix) {
                    value.removeFirst(prefix.count)
                    removedPrefix = true
                    break
                }
            }
            if value.hasSuffix("-personal") { value.removeLast("-personal".count) }
            return value
        }
        return id.caseInsensitiveCompare(accountProviderID) == .orderedSame
            || canonical(id) == canonical(accountProviderID)
    }
    public func authorisationURL(clientID: String, redirectURI: String, state: String, codeChallenge: String? = nil) -> URL? {
        let requested = ["accounts", "cards", "balance", "transactions", "offline_access"].filter { scopes.contains($0) }
        var url = URLComponents(string: "https://auth.truelayer.com/")!
        url.queryItems = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: redirectURI),
            URLQueryItem(name: "scope", value: requested.joined(separator: " ")),
            URLQueryItem(name: "providers", value: id),
            URLQueryItem(name: "provider_id", value: id),
            URLQueryItem(name: "state", value: state)
        ]
        if let codeChallenge {
            url.queryItems?.append(contentsOf: [URLQueryItem(name: "code_challenge", value: codeChallenge),
                                               URLQueryItem(name: "code_challenge_method", value: "S256")])
        }
        return url.url
    }
}

public enum CSVError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}

public enum CSVImport {
    /// Canonical format, pending confirmation of Yonder's actual export columns.
    /// Required: date,description,amount. Optional: currency,account,id,category.
    public static func parse(_ text: String, defaultAccount: String = "Yonder") throws -> [Entry] {
        let rows = try tokenize(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        guard let first = rows.first else { throw CSVError.invalid("This CSV is empty.") }
        let headers = first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        guard Set(headers).count == headers.count else { throw CSVError.invalid("Duplicate column names.") }
        if headers.contains("date/time of transaction") && headers.contains("amount (gbp)") {
            return try parseYonder(rows: Array(rows.dropFirst()), headers: headers)
        }
        for name in ["date", "description", "amount"] where !headers.contains(name) {
            throw CSVError.invalid("Missing ‘\(name)’ column. Use date,description,amount,currency,account,id,category.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return try rows.dropFirst().enumerated().map { index, row in
            guard row.count == headers.count else { throw CSVError.invalid("Row \(index + 2) has the wrong number of columns.") }
            let fields = Dictionary(uniqueKeysWithValues: zip(headers, row))
            let dateText = fields["date", default: ""].trimmingCharacters(in: .whitespaces)
            guard let date = formatter.date(from: dateText), formatter.string(from: date) == dateText else {
                throw CSVError.invalid("Row \(index + 2): date must be YYYY-MM-DD.")
            }
            let amountText = fields["amount", default: ""].trimmingCharacters(in: .whitespaces)
            guard amountText.range(of: #"^-?\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
                  let amount = Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX")) else {
                throw CSVError.invalid("Row \(index + 2): amount must be a number, with negative values for spending.")
            }
            let description = fields["description", default: ""].trimmingCharacters(in: .whitespaces)
            guard !description.isEmpty else { throw CSVError.invalid("Row \(index + 2): description is empty.") }
            let currency = fields["currency", default: "GBP"].trimmingCharacters(in: .whitespaces).uppercased()
            guard currency.range(of: #"^[A-Z]{3}$"#, options: .regularExpression) != nil else {
                throw CSVError.invalid("Row \(index + 2): currency must be a three-letter code.")
            }
            let account = fields["account", default: defaultAccount].trimmingCharacters(in: .whitespaces)
            guard !account.isEmpty else { throw CSVError.invalid("Row \(index + 2): account is empty.") }
            let categoryText = fields["category", default: ""].trimmingCharacters(in: .whitespaces)
            let category: Category
            if categoryText.isEmpty { category = amount > 0 ? .income : .other }
            else if categoryText.lowercased() == "transport" { category = .travel }
            else if let matched = Category.allCases.first(where: { $0.rawValue.lowercased() == categoryText.lowercased() }) { category = matched }
            else { throw CSVError.invalid("Row \(index + 2): unknown category ‘\(categoryText)’.") }
            let suppliedID = fields["id", default: ""].trimmingCharacters(in: .whitespaces)
            // Stable fallback identity makes reimporting the same file idempotent.
            // A bank transaction ID is preferable for identical same-day purchases.
            let identity = suppliedID.isEmpty ? [dateText, description, NSDecimalNumber(decimal: amount).stringValue, currency].joined(separator: "|") : suppliedID
            let id = "csv:" + account + ":" + identity
            return Entry(id: id, date: date, description: description, amount: amount, currency: currency, account: account, category: category)
        }
    }

    private static func parseYonder(rows: [[String]], headers: [String]) throws -> [Entry] {
        for name in ["description", "debit or credit", "category"] where !headers.contains(name) {
            throw CSVError.invalid("Yonder export is missing ‘\(name)’.")
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        // The supplied UK export has no timezone suffix. Interpret it in London.
        formatter.timeZone = TimeZone(identifier: "Europe/London")
        formatter.isLenient = false
        let formats = ["yyyy-MM-dd'T'HH:mm:ss.SSSSSS", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"]
        return try rows.enumerated().map { index, row in
            guard row.count == headers.count else { throw CSVError.invalid("Yonder row \(index + 2) has the wrong number of columns.") }
            let fields = Dictionary(uniqueKeysWithValues: zip(headers, row.map { $0.trimmingCharacters(in: .whitespaces) }))
            let dateText = fields["date/time of transaction", default: ""]
            var parsedDate: Date?
            for format in formats {
                formatter.dateFormat = format
                if let date = formatter.date(from: dateText) { parsedDate = date; break }
            }
            guard let date = parsedDate else { throw CSVError.invalid("Yonder row \(index + 2): unsupported transaction date.") }
            let amountText = fields["amount (gbp)", default: ""]
            guard amountText.range(of: #"^-?\d+(\.\d{1,2})?$"#, options: .regularExpression) != nil,
                  let raw = Decimal(string: amountText, locale: Locale(identifier: "en_US_POSIX")) else {
                throw CSVError.invalid("Yonder row \(index + 2): invalid GBP amount.")
            }
            let magnitude = raw < 0 ? -raw : raw
            let direction = fields["debit or credit", default: ""].lowercased()
            guard ["debit", "credit"].contains(direction) else { throw CSVError.invalid("Yonder row \(index + 2): expected Debit or Credit.") }
            let amount = direction == "debit" ? -magnitude : magnitude
            let description = fields["description", default: ""]
            guard !description.isEmpty else { throw CSVError.invalid("Yonder row \(index + 2): description is empty.") }
            let categoryText = fields["category", default: ""].lowercased()
            let aliases: [String: Category] = [
                "groceries": .groceries, "dining": .dining, "restaurants": .dining,
                "eating out": .dining, "food & drink": .dining,
                "transport": .travel, "transportation": .travel, "travel": .travel,
                "vehicle": .travel,
                "entertainment": .entertainment,
                "shopping": .shopping, "bills": .bills, "utilities": .bills,
                "house": .house, "workshop": .other,
                "health & beauty": .healthAndBeauty,
                "savings": .savings,
                "transfer": .transfer, "transfers": .transfer, "repayment": .transfer
            ]
            var category = aliases[categoryText] ?? .other
            if direction == "credit" && (description.lowercased().contains("repayment") || description.lowercased() == "payment received") { category = .transfer }
            // Use the settled GBP amount, never label the foreign charged amount as GBP.
            // Preserve the export timestamp for stable reimports; Yonder supplies no ID.
            let identity = [dateText, description, NSDecimalNumber(decimal: amount).stringValue, categoryText, fields["currency", default: ""], fields["amount (in charged currency)", default: ""]].joined(separator: "|")
            return Entry(id: "yonder:" + identity, date: date, description: description,
                         amount: amount, currency: "GBP", account: "Yonder", category: category)
        }
    }

    private static func tokenize(_ text: String) throws -> [[String]] {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, closed = false
        let chars = Array(normalized)
        var index = 0
        func finishRow() {
            row.append(field)
            if row.contains(where: { !$0.isEmpty }) { rows.append(row) }
            row = []; field = ""; closed = false
        }
        while index < chars.count {
            let char = chars[index]
            if quoted {
                if char == "\"" {
                    if index + 1 < chars.count && chars[index + 1] == "\"" { field.append("\""); index += 1 }
                    else { quoted = false; closed = true }
                } else { field.append(char) }
            } else if char == "," { row.append(field); field = ""; closed = false }
            else if char == "\n" { finishRow() }
            else if char == "\"" && field.isEmpty && !closed { quoted = true }
            else {
                guard !closed && char != "\"" else { throw CSVError.invalid("Malformed CSV quoting.") }
                field.append(char)
            }
            index += 1
        }
        guard !quoted else { throw CSVError.invalid("Unclosed CSV quote.") }
        if !field.isEmpty || !row.isEmpty || closed { finishRow() }
        return rows
    }
}

public enum RecurringPayments {
    public struct Key: Hashable {
        let account: String
        let merchant: String
        let currency: String
    }

    public static func key(for entry: Entry, merchantName: (Entry) -> String = { $0.merchant }) -> Key {
        let parts = entry.id.split(separator: ":")
        let account = parts.first == "truelayer" && parts.count >= 5
            ? parts.prefix(4).joined(separator: ":")
            : "\(entry.providerID ?? "csv"):\(Categorisation.merchantKey(entry.account))"
        return Key(account: account, merchant: merchantName(entry).lowercased().filter { !$0.isWhitespace }, currency: entry.currency)
    }

    /// Estimates only: never inserted into the transaction history or balances.
    /// Pending payments count as seen, preventing the estimate being counted twice.
    public static func outstanding(_ entries: [Entry], month: Date, now: Date = Date(),
                                   calendar: Calendar = .current,
                                   merchantName: (Entry) -> String = { $0.merchant }) -> [Entry] {
        guard let start = calendar.dateInterval(of: .month, for: month)?.start,
              let current = calendar.dateInterval(of: .month, for: now)?.start,
              start >= current else { return [] }
        let groups = Dictionary(grouping: entries, by: { key(for: $0, merchantName: merchantName) })
        return groups.values.compactMap { rows in
            guard rows.contains(where: { $0.recurringMonthly == true && !$0.isPending && $0.date < start }),
                  !rows.contains(where: { $0.amount < 0 && calendar.isDate($0.date, equalTo: month, toGranularity: .month) }),
                  let latest = rows.filter({ !$0.isPending && $0.amount < 0 && $0.date < start })
                    .max(by: { $0.date == $1.date ? $0.id < $1.id : $0.date < $1.date }),
                  Category.spending.contains(latest.category) else { return nil }
            return latest
        }
    }
}

public enum BudgetMath {
    public static func progress(spent: Decimal, confirmed: Decimal, budget: Decimal) -> (confirmed: Double, pending: Double) {
        guard budget > 0 else { return (0, 0) }
        let total = min(max(NSDecimalNumber(decimal: spent / budget).doubleValue, 0), 1)
        let share = spent > 0 ? min(max(NSDecimalNumber(decimal: confirmed / spent).doubleValue, 0), 1) : 0
        let settled = total * share
        return (settled, total - settled)
    }

    public static func spending(_ entries: [Entry], currency: String, month: Date, category: Category? = nil, includePending: Bool = true) -> Decimal {
        let calendar = Calendar.current
        return entries.filter {
            (includePending || !$0.isPending) && $0.currency == currency && calendar.isDate($0.date, equalTo: month, toGranularity: .month)
            && Category.spending.contains($0.category)
            && (category == nil || $0.category == category)
        }.reduce(Decimal.zero) { $0 - $1.amount - $1.reimbursedAmount }
    }
}


public struct Retailer: Codable, Sendable, Equatable {
    public var name: String?
    public var domain: String?
    public var logo_url: String?
    /// A small, user-selected image stored with the merchant override, never a file URL.
    public var customIconData: Data?
    public init(name: String?, domain: String?, logo_url: String?, customIconData: Data? = nil) {
        self.name = name; self.domain = domain; self.logo_url = logo_url; self.customIconData = customIconData
    }
    public var logoURL: URL? {
        guard customIconData == nil, let logo_url, let url = URL(string: logo_url), url.scheme == "https",
              url.host == "img.logo.dev", !logo_url.contains("sk_") else { return nil }
        return url
    }
}

public struct MerchantMatch: Codable, Sendable, Equatable {
    public var retailer: Retailer?
    public var checkedAt: Date
    public var isOverride: Bool
    public var matchingPattern: String?
    public var matchDescription: Bool?
    public init(retailer: Retailer?, checkedAt: Date = Date(), isOverride: Bool = false) {
        self.retailer = retailer; self.checkedAt = checkedAt; self.isOverride = isOverride
    }

    public func displayName(for entry: Entry) -> String {
        if isOverride && retailer == nil { return entry.description }
        return retailer?.name ?? entry.merchant
    }

}

public struct MerchantMatchingRule {
    public let owner: String
    public let match: MerchantMatch
    private let expression: NSRegularExpression

    public init(owner: String, match: MerchantMatch) throws {
        self.owner = owner
        self.match = match
        expression = try NSRegularExpression(pattern: match.matchingPattern ?? "", options: [.caseInsensitive])
    }

    public func matches(_ entry: Entry) -> Bool {
        let text = match.matchDescription == true ? entry.description : entry.merchant
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    public static func compiled(_ matches: [String: MerchantMatch]) -> [MerchantMatchingRule] {
        matches.compactMap { key, value in
            guard value.isOverride, value.retailer != nil, value.matchingPattern?.isEmpty == false else { return nil }
            return try? MerchantMatchingRule(owner: key, match: value)
        }.sorted {
            $0.match.checkedAt == $1.match.checkedAt ? $0.owner < $1.owner : $0.match.checkedAt > $1.match.checkedAt
        }
    }

    /// Reopen the saved rule even from a manually renamed transaction whose
    /// original bank text is not covered by that merchant's expression yet.
    public static func forEditing(entry: Entry, matches: [String: MerchantMatch], displayName: String) -> MerchantMatchingRule? {
        let rules = compiled(matches)
        if let active = rules.first(where: { $0.matches(entry) }) { return active }
        if let owned = rules.first(where: { $0.owner == entry.merchantKey }) { return owned }
        let name = MerchantSummary.normalisedName(displayName)
        guard !name.isEmpty else { return nil }
        return rules.first { MerchantSummary.normalisedName($0.match.retailer?.name ?? "") == name }
    }
}

public enum MerchantRecognition {
    public static let automaticMatchThreshold = 0.88

    /// Compare the full cleaned merchant name, never a shortened search query.
    public static func similarity(merchant: String, retailer: String) -> Double {
        func normalised(_ value: String) -> String {
            let cleaned = queries(for: value).first ?? ""
            var words = cleaned.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_GB"))
                .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
            let suffixes: Set<String> = ["ltd", "limited", "plc", "inc", "llc"]
            while let last = words.last, suffixes.contains(last) { words.removeLast() }
            return words.joined()
        }
        let lhs = Array(normalised(merchant)), rhs = Array(normalised(retailer))
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        if lhs == rhs { return 1 }
        // Short brand names need an exact match to avoid accidental similarities.
        guard min(lhs.count, rhs.count) > 4 else { return 0 }
        var previous = Array(0...rhs.count)
        for (i, character) in lhs.enumerated() {
            var current = [i + 1]
            for (j, other) in rhs.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1)))
            }
            previous = current
        }
        return 1 - Double(previous[rhs.count]) / Double(max(lhs.count, rhs.count))
    }

    public static func automaticMatch(for merchant: String, candidates: [Retailer]) -> Retailer? {
        var byDomain: [String: (Retailer, Double)] = [:]
        for retailer in candidates {
            guard let name = retailer.name, let domain = retailer.domain, !domain.isEmpty else { continue }
            let score = similarity(merchant: merchant, retailer: name)
            let key = domain.lowercased()
            if score > (byDomain[key]?.1 ?? -1) { byDomain[key] = (retailer, score) }
        }
        let ranked = byDomain.values.sorted { $0.1 > $1.1 }
        guard let best = ranked.first, best.1 >= automaticMatchThreshold else { return nil }
        // Similar names at different businesses require a manual choice.
        if ranked.count > 1, best.1 - ranked[1].1 < 0.08 { return nil }
        return best.0
    }

    public static func key(for merchant: String) -> String {
        Categorisation.merchantKey(merchant)
    }
    public static func queries(for merchant: String) -> [String] {
        let cleaned = merchant.replacingOccurrences(of: #"^(?:SQ|TST|PAYPAL|IZETTLE|SUMUP)\s*\*\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"(?<![A-Za-z0-9])[0-9]{2,}(?![A-Za-z0-9])"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "[*#_/]+", with: " ", options: .regularExpression)
            .split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !cleaned.isEmpty else { return [] }
        // First try the complete name, then shorten noisy store/location suffixes.
        var seen = Set<String>()
        return [cleaned.joined(separator: " "), cleaned.prefix(3).joined(separator: " "),
                cleaned.prefix(2).joined(separator: " "), cleaned.prefix(1).joined(separator: " ")]
            .filter { seen.insert($0.lowercased()).inserted }
    }
}

/// Historical months with transactions, plus the current month even before its first transaction.
public enum OverviewMonths {
    public static func available(entries: [Entry], now: Date = Date(), calendar: Calendar = .current) -> [Date] {
        let current = calendar.dateInterval(of: .month, for: now)!.start
        let months = entries.compactMap { entry -> Date? in
            guard let start = calendar.dateInterval(of: .month, for: entry.date)?.start,
                  start <= current else { return nil }
            return start
        }
        return Set(months).union([current]).sorted()
    }
}

/// All-time activity grouped by the name shown in transaction details, across accounts.
public struct MerchantSummary {
    public struct CurrencyTotal: Identifiable {
        public let currency: String
        public let transactionCount: Int
        public let totalSpend: Decimal
        public var averageTransaction: Decimal { totalSpend / Decimal(transactionCount) }
        public var id: String { currency }
    }
    public let transactionCount: Int
    public let currencies: [CurrencyTotal]

    public static func normalisedName(_ name: String) -> String {
        String(name.filter { !$0.isWhitespace }).lowercased()
    }

    public init(entries: [Entry], merchantName: String, displayName: (Entry) -> String) {
        let key = Self.normalisedName(merchantName)
        let matching = entries.filter {
            $0.amount != 0 && !key.isEmpty && Self.normalisedName(displayName($0)) == key
        }
        transactionCount = matching.count
        currencies = Dictionary(grouping: matching, by: { $0.currency.uppercased() })
            .map { currency, entries in
                CurrencyTotal(currency: currency, transactionCount: entries.count,
                    totalSpend: entries.reduce(Decimal.zero) { $0 - $1.amount - $1.reimbursedAmount })
            }
            .sorted { $0.currency < $1.currency }
    }
}

/// Shares artwork by the displayed merchant name without changing original bank names.
public enum MerchantIconSharing {
    public static func resolvedName(_ name: String, original: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? original : trimmed
    }

    public static func suggestions(for query: String, index: [String: Retailer], limit: Int = 6) -> [Retailer] {
        let key = MerchantSummary.normalisedName(query)
        guard !key.isEmpty, limit > 0 else { return [] }
        return index.keys.filter { $0.contains(key) }.sorted { lhs, rhs in
            if lhs.hasPrefix(key) != rhs.hasPrefix(key) { return lhs.hasPrefix(key) }
            return lhs < rhs
        }.prefix(limit).compactMap { index[$0] }
    }

    private static func validMatch(_ key: String, matches: [String: MerchantMatch]) -> MerchantMatch? {
        guard let match = matches[key] else { return nil }
        if !match.isOverride, let retailer = match.retailer,
           MerchantRecognition.similarity(merchant: key, retailer: retailer.name ?? "") < MerchantRecognition.automaticMatchThreshold {
            return nil
        }
        return match
    }

    public static func index(matches: [String: MerchantMatch]) -> [String: Retailer] {
        // Explicit selections/removals win over automatic matches; the latest edit wins.
        let ordered = matches.keys.sorted { lhs, rhs in
            let a = matches[lhs]!, b = matches[rhs]!
            if a.isOverride != b.isOverride { return !a.isOverride }
            if a.checkedAt != b.checkedAt { return a.checkedAt < b.checkedAt }
            return lhs < rhs
        }
        var result: [String: Retailer] = [:]
        for key in ordered {
            guard let match = validMatch(key, matches: matches), let retailer = match.retailer,
                  let name = retailer.name else { continue }
            let normalised = MerchantSummary.normalisedName(name)
            guard !normalised.isEmpty else { continue }
            // Retain icon-less manual overrides: they represent explicit removal.
            if match.isOverride || retailer.customIconData != nil || retailer.logoURL != nil {
                result[normalised] = retailer
            }
        }
        return result
    }

    public static func applyingIcon(_ source: Retailer, to retailer: Retailer) -> Retailer {
        var result = retailer
        result.domain = source.domain
        result.logo_url = source.logo_url
        result.customIconData = source.customIconData
        return result
    }

    public static func updating(_ retailer: Retailer, for entry: Entry, entries: [Entry],
                                matches: [String: MerchantMatch], now: Date = Date()) -> [String: MerchantMatch] {
        var result = matches
        let target = MerchantSummary.normalisedName(retailer.name ?? "")
        guard !target.isEmpty else { return result }
        var names: [String: String] = [:]
        for key in matches.keys {
            if let name = validMatch(key, matches: matches)?.retailer?.name, MerchantSummary.normalisedName(name) == target {
                names[key] = name
            }
        }
        for transaction in entries {
            let key = MerchantRecognition.key(for: transaction.merchant)
            let name = validMatch(key, matches: matches)?.displayName(for: transaction) ?? transaction.merchant
            if MerchantSummary.normalisedName(name) == target { names[key] = name }
        }
        for (key, name) in names {
            let original = result[key]?.retailer ?? Retailer(name: name, domain: nil, logo_url: nil)
            var updated = applyingIcon(retailer, to: original)
            updated.name = name
            var match = MerchantMatch(retailer: updated, checkedAt: now, isOverride: true)
            match.matchingPattern = result[key]?.matchingPattern
            match.matchDescription = result[key]?.matchDescription
            if match.matchingPattern != nil, let savedAt = result[key]?.checkedAt { match.checkedAt = savedAt }
            result[key] = match
        }
        let key = MerchantRecognition.key(for: entry.merchant)
        var match = MerchantMatch(retailer: retailer, checkedAt: now, isOverride: true)
        match.matchingPattern = result[key]?.matchingPattern
        match.matchDescription = result[key]?.matchDescription
        result[key] = match
        return result
    }
}
