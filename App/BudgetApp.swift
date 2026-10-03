import SwiftUI
import UniformTypeIdentifiers
import AuthenticationServices
import BackgroundTasks
import OSLog

@MainActor
final class BankAuthorisationSession: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var generation = UUID()

    func start(url: URL, completion: @escaping (Result<URL, Error>) -> Void) throws {
        cancel()
        let requestID = generation
        let handler: ASWebAuthenticationSession.CompletionHandler = { [weak self] url, error in
            Task { @MainActor in
                guard let self, self.generation == requestID else { return }
                self.session = nil
                if let url { completion(.success(url)) }
                else { completion(.failure(error ?? ASWebAuthenticationSessionError(.canceledLogin))) }
            }
        }
        let session: ASWebAuthenticationSession
        if #available(iOS 17.4, *) {
            session = ASWebAuthenticationSession(url: url, callback: .customScheme(BankService.appCallbackScheme), completionHandler: handler)
        } else {
            session = ASWebAuthenticationSession(url: url, callbackURLScheme: BankService.appCallbackScheme, completionHandler: handler)
        }
        session.presentationContextProvider = self
        self.session = session
        guard session.start() else {
            self.session = nil
            throw CSVError.invalid("Could not open bank authorisation. Please try again.")
        }
    }

    func cancel() {
        generation = UUID()
        session?.cancel()
        session = nil
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
}

private let ink = Color(red: 0.12, green: 0.22, blue: 0.19)
private let paper = Color(red: 0.96, green: 0.95, blue: 0.92)
private let moneyIn = Color(red: 0.10, green: 0.46, blue: 0.25)
private let mutedIncome = Color(red: 0.42, green: 0.59, blue: 0.48)
private let overBudget = Color(red: 0.76, green: 0.48, blue: 0.44)

extension Category {
    var color: Color {
        let hex: UInt32
        switch self {
        case .groceries: hex = 0x718238
        case .dining: hex = 0xB66B35
        case .travel: hex = 0x3184AC
        case .entertainment: hex = 0x8155A3
        case .shopping: hex = 0xAA487C
        case .bills: hex = 0xA08A2F
        case .house: hex = 0x52649C
        case .healthAndBeauty: hex = 0xC17175
        case .savings: hex = 0x28776F
        case .other: hex = 0x8B7057
        case .income: hex = 0x449365
        case .transfer: hex = 0x879295
        }
        return Color(red: Double((hex >> 16) & 255) / 255,
                     green: Double((hex >> 8) & 255) / 255,
                     blue: Double(hex & 255) / 255)
    }
}

private struct CategoryLabel: View {
    let category: Category
    var body: some View {
        Label {
            Text(category.rawValue)
        } icon: {
            Image(systemName: category.symbol)
                .symbolVariant(.none)
                .foregroundStyle(category.color)
        }
    }
}

private struct HighlightedRowStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 8)
                    .fill(configuration.isPressed ? Color(uiColor: .systemGray5) : .clear)
                    .padding(.horizontal, -8)
            }
            .contentShape(Rectangle())
    }
}

/// Brand icons are bundled as PNGs for reliable offline rendering.
struct BankLogo: View {
    var provider: BankProvider?
    var fallback = "B"
    var size: CGFloat = 44
    var accountKind: String? = nil
    private var usesBarclaycardLogo: Bool {
        provider?.id == "ob-barclaycard" ||
            (accountKind == "cards" && ["ob-barclays", "ob-barclays-business"].contains(provider?.id ?? ""))
    }
    private var bundledImage: UIImage? {
        guard let provider,
              let url = Bundle.main.url(forResource: usesBarclaycardLogo ? "ob-barclaycard" : provider.id,
                                        withExtension: "png", subdirectory: "BankIcons") else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
    private var trustedURL: URL? {
        guard let url = provider?.brandIconURL, url.scheme == "https",
              ["providers-assets.truelayer.com", "truelayer-provider-assets.s3.amazonaws.com"].contains(url.host ?? "") else { return nil }
        return url
    }
    var body: some View {
        ZStack {
            Circle().fill(.white)
            if provider == nil, fallback == "Y",
               let url = Bundle.main.url(forResource: "yonder", withExtension: "jpg", subdirectory: "BankIcons"),
               let image = UIImage(contentsOfFile: url.path) {
                Image(uiImage: image).resizable().scaledToFill()
            } else if let bundledImage {
                if !usesBarclaycardLogo && (provider?.id == "ob-barclays" || provider?.id == "ob-barclays-business") {
                    LinearGradient(colors: [Color(red: 0, green: 0.77, blue: 0.94),
                                            Color(red: 0, green: 0.53, blue: 0.74)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                        .mask(Image(uiImage: bundledImage).resizable().scaledToFit())
                        .padding(logoInset)
                } else {
                    Image(uiImage: bundledImage).resizable().scaledToFit()
                        .padding(logoInset)
                }
            } else if let url = trustedURL {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFit()
                    } else {
                        fallbackInitial
                    }
                }
            } else {
                fallbackInitial
            }
        }
        .frame(width: size, height: size).clipShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(usesBarclaycardLogo ? "Barclaycard" : provider?.name ?? (fallback == "Y" ? "Yonder" : "Account"))
    }
    private var logoInset: CGFloat {
        if usesBarclaycardLogo { return 0 }
        switch provider?.id {
        case "ob-barclays", "ob-barclays-business":
            return size * 0.10
        default:
            return 0
        }
    }
    private var fallbackInitial: some View {
        Text(provider.map { String($0.name.prefix(1)) } ?? fallback)
            .font(.system(size: size * 0.4, weight: .semibold)).foregroundStyle(ink)
    }
}

struct BankPickerView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""
    private var filtered: [BankProvider] {
        store.providers.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) }
    }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose your bank or credit card").font(.title3.weight(.semibold))
                    Text("UK connections available through TrueLayer").font(.subheadline).foregroundStyle(.secondary)
                }.listRowBackground(Color.clear)
                if store.loadingProviders && store.providers.isEmpty {
                    HStack { Spacer(); ProgressView("Loading banks…"); Spacer() }.listRowBackground(Color.clear)
                }
                if let error = store.providerError {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(error).font(.subheadline).foregroundStyle(.secondary)
                        Button("Try again") { Task { await store.loadProviders() } }
                    }
                }
                ForEach(filtered) { provider in
                    let added = store.sources.contains(where: { $0.id == provider.id })
                    Button {
                        store.addSource(provider); dismiss()
                    } label: {
                        HStack(spacing: 14) {
                            BankLogo(provider: provider, size: 46)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(provider.name).font(.subheadline.weight(.semibold)).foregroundStyle(ink)
                                Text(provider.capabilityDescription).font(.caption).foregroundStyle(.secondary)
                                if let status = provider.availability?.status, status != "healthy" {
                                    Text("Service status: \(status)").font(.caption).foregroundStyle(.orange)
                                }
                            }
                            Spacer()
                            Image(systemName: added ? "checkmark.circle.fill" : "plus.circle")
                                .foregroundStyle(ink)
                        }.padding(.vertical, 6)
                    }.disabled(added).accessibilityLabel("\(provider.name), \(added ? "already added" : "add bank")")
                }
                if filtered.isEmpty && !store.loadingProviders && store.providerError == nil {
                    ContentUnavailableView.search(text: search)
                }
            }.scrollContentBackground(.hidden).background(paper)
                .navigationTitle("Add a bank").navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Search banks and cards")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
                .task { await store.loadProviders() }
        }
    }
}

struct BankSourceView: View {
    let provider: BankProvider
    @AppStorage("developerModeEnabled") private var developerMode = false
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.openURL) private var openURL
    @Environment(\.dismiss) private var dismiss
    @State private var editingTrueLayer = false
    @State private var hasClientSecret = false
    @State private var code = ""
    @State private var accessToken = ""
    @State private var authorisationState: String?
    @State private var showingTransactionCheck = false
    @State private var error: String?
    private var busy: Bool { store.isBankSyncing || store.authorisingBankID != nil }
    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(ink)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 16) {
                        BankLogo(provider: provider, size: 56)
                        VStack(alignment: .leading, spacing: 5) {
                            sectionHeading(provider.name)
                            Text(store.bankStatus(provider.id)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        if store.bankCredentialIDs.contains(provider.id) {
                            Button { Task { await run { try await store.syncBank(provider) } } } label: {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                    .font(.title3).foregroundStyle(ink)
                                    .frame(width: 44, height: 44).contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless).disabled(busy)
                            .accessibilityLabel("Sync \(provider.name)")
                        }
                    }
                    if let synced = store.bankSyncedAt[provider.id], let date = try? BankSync.date(synced) {
                        Text("Last synced \(date.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if store.busyBank == provider.id { ProgressView("Connecting to your bank…") }
                    if let error = error ?? store.bankAuthorisationError { Text(error).font(.subheadline).foregroundStyle(overBudget) }
                    if store.bankSyncWarnings.contains(provider.id) {
                        Text("Notes or category changes on indistinguishable purchases may need checking after a sync.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let accounts = store.bankAccounts[provider.id], !accounts.isEmpty {
                    Section {
                        ForEach(accounts) { account in
                            NavigationLink {
                                TransactionsView(accountFilter: nil, idPrefix: account.id)
                            } label: {
                                HStack {
                                    Text(account.name)
                                    Spacer()
                                    if let current = account.current, let value = Decimal(string: current) {
                                        Text(money(value, account.currency)).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } header: { sectionHeading("Accounts and cards") }
                }
                if developerMode, let report = store.bankCategoryReports[provider.id] {
                    Section {
                        Text(report).font(.caption).textSelection(.enabled)
                        ShareLink(item: report) { Label("Share category summary", systemImage: "square.and.arrow.up") }
                    } header: { sectionHeading("Bank categories") }
                }
                if !store.isDemoSession {
                Section {
                    if !hasClientSecret {
                        Button("Set up TrueLayer") { editingTrueLayer = true }
                        Text("Add your shared client secret in API Credentials to connect your banks.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if BankService.automaticRedirectURI != nil {
                        Button(store.bankCredentialIDs.contains(provider.id) ? "Reconnect with bank" : "Connect with bank") {
                            do { try store.authoriseBank(provider) }
                            catch { self.error = error.localizedDescription }
                        }.disabled(busy || !hasClientSecret)
                        if store.authorisingBankID == provider.id {
                            ProgressView("Waiting for bank authorisation…")
                            Button("Cancel") { store.cancelBankAuthorisation() }
                        }
                    }
                    if BankService.automaticRedirectURI == nil || developerMode {
                    Button("Authorise with bank") {
                        let state = UUID().uuidString
                        authorisationState = state
                        if let url = provider.authorisationURL(clientID: BankService.clientID,
                            redirectURI: BankService.redirectURI, state: state) { openURL(url) }
                    }.disabled(busy || !hasClientSecret)
                    SecureField("Full TrueLayer redirect URL", text: $code)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Text("After authorising, copy the full URL from the browser’s address bar and paste it here within five minutes. This lets us verify it belongs to this bank’s authorisation.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Connect and import") {
                        Task {
                            await run {
                                try await store.connectBank(provider, code: code, state: authorisationState)
                                code = ""
                            }
                        }
                    }.disabled(busy || !hasClientSecret || code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } header: { sectionHeading("Bank connection") }
                }
                if developerMode && !store.isDemoSession {
                    Section {
                        Button("Find missing transaction") { showingTransactionCheck = true }
                            .disabled(busy || !store.bankCredentialIDs.contains(provider.id))
                    } header: { sectionHeading("Diagnostics") }
                    Section {
                        SecureField("Access token", text: $accessToken)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                        Text("No client secret is needed for this option. When the token expires, paste a new one.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Save token and import") {
                            Task {
                                await run {
                                    try await store.importBankToken(accessToken, provider: provider)
                                    accessToken = ""
                                }
                            }
                        }.disabled(busy || accessToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    } header: { sectionHeading("Use an existing access token") }
                }
                if store.bankCredentialIDs.contains(provider.id) {
                    Section {
                        Button("Remove saved bank tokens", role: .destructive) {
                            do { try store.bankService.forget(provider.id); store.loadBankStatus() }
                            catch { self.error = error.localizedDescription }
                        }.disabled(busy)
                        Text("Imported transactions, notes and category changes are kept.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }.scrollContentBackground(.hidden).background(paper)
                .navigationTitle(provider.name).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(busy) } }
                .interactiveDismissDisabled(busy)
                .onChange(of: developerMode) { _, enabled in
                    if !enabled { accessToken = "" }
                }
                .onAppear { hasClientSecret = store.bankService.hasClientSecret }
                .sheet(isPresented: $editingTrueLayer, onDismiss: {
                    hasClientSecret = store.bankService.hasClientSecret
                }) { APICredentialView(service: .trueLayer) }
                .sheet(isPresented: $showingTransactionCheck) {
                    BankTransactionCheckView(provider: provider)
                }
                .onDisappear { code = ""; accessToken = "" }
        }
    }
    private func run(_ action: () async throws -> Void) async {
        error = nil
        do { try await action() }
        catch { self.error = error.localizedDescription }
    }
}

private struct BankTransactionCheckView: View {
    let provider: BankProvider
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var report: String?
    @State private var error: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Description or amount, e.g. 36", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("Check bank response") {
                        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        checking = true; report = nil; error = nil
                        Task { @MainActor in
                            defer { checking = false }
                            do { report = try await store.checkBankTransactions(provider, query: search) }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                    .disabled(checking || store.isBankSyncing || query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if checking { ProgressView("Checking settled and pending responses…") }
                    if let error { Text(error).foregroundStyle(.red) }
                } footer: {
                    Text("Fetches fresh bank data and compares it with Budget’s saved transactions. Does not import or delete transactions. Reports contain the descriptions and amounts of matching payments.")
                }
                if let report {
                    Section {
                        Text(report).font(.caption).textSelection(.enabled)
                        ShareLink(item: report) { Label("Share diagnostic report", systemImage: "square.and.arrow.up") }
                    }
                }
            }
            .scrollContentBackground(.hidden).background(paper)
            .navigationTitle("Find transaction").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() }.disabled(checking) }
            }
            .interactiveDismissDisabled(checking)
        }
    }
}

struct CSVPreview: Identifiable {
    let id = UUID()
    let entries: [Entry]
}

@MainActor
final class BudgetStore: ObservableObject {
    let isDemoSession: Bool
    @Published var bankAuthorisationError: String?
    @Published var authorisingBankID: String?
    @Published private(set) var pendingBankCallback: URL?
    private var completingBankAuthorisation = false
    private let bankAuthorisationSession = BankAuthorisationSession()
    @Published var entries: [Entry] = []
    @Published var budgets: [String: Decimal] = [:]
    @Published var isDemo = true
    @Published var message: String?
    @Published var sources: [BankProvider] = []
    @Published var providers: [BankProvider] = []
    @Published var providerError: String?
    @Published var loadingProviders = false
    @Published var merchantRules: [String: Category] = [:]
    @Published var storageError: String?
    @Published var importPreview: CSVPreview?
    let bankService: BankService
    let logoService: LogoDevService
    let logoCache = RetailerLogoCache(directory: URL.applicationSupportDirectory
        .appendingPathComponent("Budget/TransactionLogos", isDirectory: true))
    private var logoCacheTask: Task<Void, Never>?
    private var logoCacheURLs: Set<URL>?
    private var logoCacheRevision = 0
    @Published var merchantMatches: [String: MerchantMatch] = [:] {
        didSet {
            merchantIconIndex = MerchantIconSharing.index(matches: merchantMatches)
            merchantMatchingRules = MerchantMatchingRule.compiled(merchantMatches)
        }
    }
    private var merchantMatchingRules: [MerchantMatchingRule] = []
    private var merchantIconIndex: [String: Retailer] = [:]
    @Published var recognisingRetailers = false
    @Published var retailerLookupSummary: String?
    @Published var busyBank: String?
    @Published var syncingAllBanks = false
    @Published var bankSyncSummary: String?
    private var automaticSyncAttempts = UserDefaults.standard.dictionary(forKey: "bankAutomaticSyncAttempts") as? [String: Date] ?? [:]
    var isBankSyncing: Bool { busyBank != nil || syncingAllBanks }
    @Published var bankCredentialIDs: Set<String> = []
    @Published var bankAccounts: [String: [BankAccount]] = [:]
    @Published var bankSyncedAt: [String: String] = [:]
    @Published var bankCategoryReports: [String: String] = [:]
    @Published var bankSyncWarnings: Set<String> = []
    @Published var banksNeedingAuthorisation: Set<String> = []
    private var repository: BudgetRepository?

    init(isDemoSession: Bool = false) {
        self.isDemoSession = isDemoSession
        bankService = isDemoSession ? BankService(readSecret: { _ in nil },
            writeSecret: { _, _ in throw CSVError.invalid("Bank connections are disabled in demo mode.") },
            removeSecret: { _ in }) : BankService()
        logoService = LogoDevService(isEnabled: !isDemoSession)
        if isDemoSession {
            let data = DemoDataset()
            entries = data.entries; budgets = data.budgets; sources = data.providers
            providers = data.providers; bankAccounts = data.accounts; isDemo = true
        } else {
            openStorage(); loadBankStatus()
        }
    }

    var visibleEntries: [Entry] {
        TransferMatching.apply(to: entries.filter { $0.amount != 0 }, rules: merchantRules)
    }

    var offlineAccounts: [String] {
        let imported = entries.filter { $0.id.hasPrefix("csv:") || $0.id.hasPrefix("yonder:") }
        return Set(imported.map(\.account)).union(["Yonder"])
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var snapshot: BudgetSnapshot {
        BudgetSnapshot(entries: entries, budgets: budgets, isDemo: isDemo, sources: sources, merchantRules: merchantRules, merchantMatches: merchantMatches)
    }

    private func restore(_ state: BudgetSnapshot) {
        entries = state.entries; budgets = state.budgets; isDemo = state.isDemo
        sources = state.sources; merchantRules = state.merchantRules; merchantMatches = state.merchantMatches
    }

    func openStorage() {
        guard !isDemoSession else { return }
        do {
            let directory = URL.applicationSupportDirectory.appendingPathComponent("Budget", isDirectory: true)
            let opened = try BudgetRepository(storeURL: directory.appendingPathComponent("Budget.store"))
            repository = opened
            logoService.repository = opened
            if let state = try opened.load() { restore(state) }
            else { loadDemo(); try opened.save(snapshot) }
            storageError = nil
            refreshLogoCache()
        } catch {
            repository = nil
            logoService.repository = nil
            storageError = "Your saved data could not be opened. It has not been reset. Try again when your device is unlocked."
        }
    }

    func loadDemo() {
        isDemo = true
        budgets = ["Groceries": 300, "Dining": 200, "Travel": 120, "Shopping": 180, "Bills": 950, "Other": 100]
        let rows: [(String, Decimal, Category)] = [
            ("Waitrose", -42.80, .groceries), ("Neighbourhood coffee", -4.50, .dining),
            ("Transport for London", -8.10, .travel), ("Rent", -850, .bills),
            ("Dinner with friends", -38, .dining), ("Uniqlo", -49.90, .shopping),
            ("Salary", 3200, .income), ("Card repayment", -150, .transfer)
        ]
        entries = rows.enumerated().map { index, row in
            let start = Calendar.current.dateInterval(of: .month, for: Date())!.start
            let date = Calendar.current.date(byAdding: .day, value: min(index, Calendar.current.component(.day, from: Date()) - 1), to: start)!
            return Entry(id: "demo-\(index)", date: date, description: row.0, amount: row.1, account: "Revolut · Demo", category: row.2, providerID: "ob-revolut")
        }
    }

    @discardableResult
    func save() -> Bool {
        if isDemoSession { return true } // Demo edits remain in this store's memory only.
        guard let repository else { return false }
        do {
            try repository.save(snapshot)
            refreshLogoCache()
            return true
        } catch {
            // Failed writes roll back in SwiftData and restore the UI's last
            // persisted state rather than presenting changes as saved.
            do {
                if let previous = try repository.load() { restore(previous) }
            } catch { storageError = "Your saved data could not be reopened. It has not been reset." }
            message = "Your changes could not be saved. Please try again."
            return false
        }
    }

    func loadProviders() async {
        guard !isDemoSession else { return }
        guard !loadingProviders else { return }
        loadingProviders = true; providerError = nil
        defer { loadingProviders = false }
        do {
            let url = URL(string: "https://auth.truelayer.com/api/providers?country=uk&clientId=budget-2f2bbc")!
            var request = URLRequest(url: url)
            request.timeoutInterval = 20
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
            let catalogue = try JSONDecoder().decode([BankProvider].self, from: data)
            providers = catalogue.filter(\.isUKDataProvider).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if providers.isEmpty { providerError = "No UK connections are available for this app right now." }
            // Refresh stored branding without changing the user's selected sources.
            sources = sources.map { saved in providers.first(where: { $0.id == saved.id }) ?? saved }
        } catch is CancellationError { }
        catch { providerError = "Couldn't load banks. Check your connection and try again." }
    }

    @discardableResult
    func loadBankStatus() -> String? {
        if isDemoSession { return nil }
        bankCredentialIDs = []; bankAccounts = [:]; bankSyncedAt = [:]; bankCategoryReports = [:]
        do {
            for source in sources {
                if let credential = try bankService.credential(source.id) {
                    bankCredentialIDs.insert(source.id)
                    bankAccounts[source.id] = credential.accounts
                    bankSyncedAt[source.id] = credential.syncedAt
                    bankCategoryReports[source.id] = credential.categoryReport
                }
            }
            return nil
        } catch {
            message = error.localizedDescription
            return error.localizedDescription
        }
    }
    func bankStatus(_ providerID: String) -> String {
        if isDemoSession { return "Demo account" }
        if banksNeedingAuthorisation.contains(providerID) { return "Reconnect this bank" }
        if bankSyncedAt[providerID] != nil { return "Connected" }
        return bankCredentialIDs.contains(providerID) ? "Ready to sync" : "Awaiting authorisation"
    }
    func connectBank(_ provider: BankProvider, code: String, state: String?) async throws {
        guard !isDemoSession else { return }
        guard !isBankSyncing else { return }
        try await bankAction(provider) {
            try await self.bankService.connect(provider, code: code, expectedState: state)
            return try await self.bankService.sync(provider)
        }
    }

    func authoriseBank(_ provider: BankProvider) throws {
        guard !isDemoSession else { return }
        guard !isBankSyncing, authorisingBankID == nil,
              let redirect = BankService.automaticRedirectURI else { return }
        bankAuthorisationError = nil
        let url = try bankService.beginAuthorisation(provider, redirectURI: redirect)
        authorisingBankID = provider.id
        do {
            try bankAuthorisationSession.start(url: url) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success(let callback): self.receiveBankCallback(callback)
                case .failure(let error):
                    self.cancelBankAuthorisation()
                    if (error as? ASWebAuthenticationSessionError)?.code != .canceledLogin {
                        self.bankAuthorisationError = "Could not authorise the bank. Please try again."
                        self.message = self.bankAuthorisationError
                    }
                }
            }
        } catch {
            cancelBankAuthorisation()
            throw error
        }
    }

    func cancelBankAuthorisation() {
        bankAuthorisationSession.cancel()
        authorisingBankID = nil
        pendingBankCallback = nil
        do { try bankService.cancelAuthorisation() }
        catch { message = error.localizedDescription }
    }

    @discardableResult
    func receiveBankCallback(_ url: URL) -> Bool {
        guard !isDemoSession else { return false }
        guard url.scheme == BankService.appCallbackScheme, url.host == "truelayer", url.path == "/callback" else { return false }
        guard !completingBankAuthorisation, pendingBankCallback != url else { return true }
        pendingBankCallback = url
        return true
    }

    func completePendingBankAuthorisation() async {
        guard !isBankSyncing, !completingBankAuthorisation, let callback = pendingBankCallback else { return }
        completingBankAuthorisation = true
        defer { completingBankAuthorisation = false }
        do {
            // Check the saved state before dismissing a live browser session.
            guard let pending = try bankService.pendingAuthorisation() else {
                throw CSVError.invalid("This bank authorisation is no longer active. Connect the bank again.")
            }
            _ = try BankService.validateAuthorisationCallback(callback.absoluteString, redirectURI: pending.redirectURI, expectedState: pending.state)
            bankAuthorisationSession.cancel()
            authorisingBankID = nil
            try await bankAction(pending.provider) {
                let provider = try await self.bankService.completeAuthorisation(callback)
                return try await self.bankService.sync(provider)
            }
        } catch {
            bankAuthorisationError = error.localizedDescription
            message = error.localizedDescription
        }
        pendingBankCallback = nil
    }
    func importBankToken(_ token: String, provider: BankProvider) async throws {
        guard !isDemoSession else { return }
        guard !isBankSyncing else { return }
        try await bankAction(provider) {
            try await self.bankService.useAccessToken(token, provider: provider)
            return try await self.bankService.sync(provider)
        }
    }
    func syncBank(_ provider: BankProvider) async throws {
        guard !isDemoSession else { return }
        guard !isBankSyncing else { return }
        try await bankAction(provider) { try await self.bankService.sync(provider) }
    }
    @discardableResult
    func syncAllBanks(automatic: Bool = false) async -> Bool {
        guard !isDemoSession else { return false }
        guard !isBankSyncing, storageError == nil else { return false }
        let credentialError = loadBankStatus()
        let now = Date()
        let eligible = sources.filter { source in
            guard bankCredentialIDs.contains(source.id) else { return false }
            return !automatic || BankSyncSchedule.isDue(
                lastSuccess: bankSyncedAt[source.id].flatMap { try? BankSync.date($0) },
                lastAutomaticAttempt: automaticSyncAttempts[source.id], now: now)
        }.sorted {
            (bankSyncedAt[$0.id].flatMap { try? BankSync.date($0) } ?? .distantPast)
                < (bankSyncedAt[$1.id].flatMap { try? BankSync.date($0) } ?? .distantPast)
        }
        guard !eligible.isEmpty else {
            if !automatic {
                bankSyncSummary = credentialError.map { "Could not read bank connections: \($0)" }
                    ?? "No connected banks are available to sync. Reconnect in Accounts."
            }
            return false
        }
        syncingAllBanks = true; bankSyncSummary = nil
        defer { syncingAllBanks = false }
        var successes = 0
        var failures: [String] = []
        for bank in eligible {
            if Task.isCancelled {
                bankSyncSummary = "Sync cancelled. Pull down to retry."
                return true
            }
            if automatic {
                automaticSyncAttempts[bank.id] = Date()
                UserDefaults.standard.set(automaticSyncAttempts, forKey: "bankAutomaticSyncAttempts")
            }
            do {
                try await bankAction(bank) { try await self.bankService.sync(bank) }
                successes += 1
            } catch {
                if Task.isCancelled {
                    bankSyncSummary = "Sync cancelled. Pull down to retry."
                    return true
                }
                failures.append("\(bank.name): \(error.localizedDescription)")
            }
        }
        let summary = "Synced \(successes) of \(eligible.count) banks."
        bankSyncSummary = ([summary] + failures).joined(separator: "\n")
        return true
    }

    func checkBankTransactions(_ provider: BankProvider, query: String) async throws -> String {
        guard !isDemoSession, !isBankSyncing, authorisingBankID == nil else {
            throw CSVError.invalid("Finish the current bank action before checking transactions.")
        }
        busyBank = provider.id
        defer { busyBank = nil }
        let response = try await bankService.sync(provider)
        return response.transactionReport(query: query, saved: entries)
    }

    private func bankAction(_ provider: BankProvider, action: () async throws -> BankSync) async throws {
        guard busyBank == nil else { return }
        busyBank = provider.id
        defer { busyBank = nil; loadBankStatus() }
        let result: BankSync
        do { result = try await action() }
        catch {
            if error is BankService.WrongBankToken { banksNeedingAuthorisation.insert(provider.id) }
            throw error
        }
        banksNeedingAuthorisation.remove(provider.id)
        try Task.checkCancellation()
        if !result.warnings.isEmpty { bankSyncWarnings.insert(provider.id) }
        let merged = try result.merging(into: isDemo ? [] : entries, rules: merchantRules)
        if isDemo { budgets = [:]; isDemo = false }
        entries = merged
        guard save() else { throw CSVError.invalid("Bank data could not be saved. Try syncing again.") }
        try bankService.recordSuccessfulSync(result)
        Task { await self.recogniseMerchants() }
    }

    func retailerMatch(forKey key: String) -> MerchantMatch? {
        guard let match = merchantMatches[key] else { return nil }
        // A scoped regex must never rename every payment from a processor such
        // as Zettle merely because the source merchant key is shared.
        guard match.matchingPattern?.isEmpty != false else { return nil }
        if !match.isOverride, let retailer = match.retailer,
           MerchantRecognition.similarity(merchant: key, retailer: retailer.name ?? "") < MerchantRecognition.automaticMatchThreshold {
            return MerchantMatch(retailer: nil, checkedAt: match.checkedAt)
        }
        return match
    }
    func matchingRule(for entry: Entry) -> MerchantMatchingRule? {
        merchantMatchingRules.first { $0.matches(entry) }
    }
    func retailerMatch(for entry: Entry) -> MerchantMatch? {
        matchingRule(for: entry)?.match ?? retailerMatch(forKey: MerchantRecognition.key(for: entry.merchant))
    }
    func existingMerchantIcon(named name: String) -> Retailer? {
        merchantIconIndex[MerchantSummary.normalisedName(name)]
    }
    func merchantSuggestions(for query: String) -> [Retailer] {
        MerchantIconSharing.suggestions(for: query, index: merchantIconIndex)
    }
    func retailer(for entry: Entry) -> Retailer? {
        let matched = retailerMatch(for: entry)?.retailer
        let name = retailerName(for: entry)
        guard let shared = existingMerchantIcon(named: name) else { return matched }
        return MerchantIconSharing.applyingIcon(shared,
            to: matched ?? Retailer(name: name, domain: nil, logo_url: nil))
    }
    func refreshLogoCache(force: Bool = false) {
        guard !isDemoSession else { return }
        guard repository != nil, storageError == nil else { return }
        // Include every saved month/account, not just the current list or filter.
        let urls = Set(entries.compactMap { retailer(for: $0)?.logoURL })
        guard force || urls != logoCacheURLs else { return }
        logoCacheURLs = urls
        logoCacheRevision += 1
        let revision = logoCacheRevision
        logoCacheTask?.cancel()
        logoCacheTask = Task { [logoCache] in
            do { try await logoCache.retain(urls, revision: revision) }
            catch { return } // Leave existing artwork intact if storage is unavailable.
            await withTaskGroup(of: Void.self) { group in
                var pending = urls.makeIterator()
                for _ in 0..<4 {
                    if let url = pending.next() {
                        group.addTask { _ = try? await logoCache.data(for: url) }
                    }
                }
                while await group.next() != nil {
                    guard !Task.isCancelled else { group.cancelAll(); return }
                    if let url = pending.next() {
                        group.addTask { _ = try? await logoCache.data(for: url) }
                    }
                }
            }
        }
    }
    func retailerName(for entry: Entry) -> String { retailerMatch(for: entry)?.displayName(for: entry) ?? entry.merchant }
    func selectRetailer(_ retailer: Retailer, for entry: Entry) {
        guard retailer.name?.isEmpty == false, retailer.domain?.isEmpty == false else { return }
        merchantMatches[MerchantRecognition.key(for: entry.merchant)] = MerchantMatch(retailer: retailer, isOverride: true)
        save()
    }
    func saveCustomRetailer(_ retailer: Retailer, for entry: Entry, matchingPattern: String = "", matchDescription: Bool = false, ruleOwner: String? = nil) -> Bool {
        guard let name = retailer.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return false }
        if !matchingPattern.isEmpty {
            do { _ = try NSRegularExpression(pattern: matchingPattern, options: [.caseInsensitive]) }
            catch { message = "Invalid matching rule: \(error.localizedDescription)"; return false }
        }
        let previous = merchantMatches
        var custom = retailer
        custom.name = name
        merchantMatches = MerchantIconSharing.updating(custom, for: entry, entries: entries, matches: merchantMatches)
        let key = MerchantRecognition.key(for: entry.merchant)
        if !matchingPattern.isEmpty {
            // Store separate rules for different businesses sharing a payment
            // processor, without creating a processor-wide manual override.
            merchantMatches[key] = previous[key]
        }
        let owner = ruleOwner ?? (matchingPattern.isEmpty ? key : "regex:\(UUID().uuidString)")
        var match = MerchantMatch(retailer: custom, isOverride: true)
        match.matchingPattern = matchingPattern.isEmpty ? nil : matchingPattern
        match.matchDescription = matchDescription
        merchantMatches[owner] = match
        guard save() else {
            merchantMatches = previous
            return false
        }
        return true
    }
    func useOriginalRetailer(for entry: Entry) {
        merchantMatches[MerchantRecognition.key(for: entry.merchant)] = MerchantMatch(retailer: nil, isOverride: true)
        save()
    }
    func recogniseMerchants() async {
        guard !recognisingRetailers, logoService.hasKey, !isDemo, storageError == nil else { return }
        recognisingRetailers = true; retailerLookupSummary = nil
        defer { recognisingRetailers = false }
        let merchants = Dictionary(grouping: visibleEntries, by: { MerchantRecognition.key(for: $0.merchant) })
        let pending = merchants.keys.sorted().filter { retailerMatch(forKey: $0) == nil }
        var found = 0, missed = 0
        for key in pending {
            if Task.isCancelled { return }
            guard let merchant = merchants[key]?.first?.merchant else { continue }
            do {
                var match: Retailer?
                var candidates: [Retailer] = []
                for query in MerchantRecognition.queries(for: merchant) {
                    candidates += try await logoService.lookup(description: query)
                    match = MerchantRecognition.automaticMatch(for: merchant, candidates: candidates)
                    if match != nil { break }
                }
                try Task.checkCancellation()
                // A user selection made during a lookup always wins.
                if retailerMatch(forKey: key)?.isOverride == true { continue }
                merchantMatches[key] = MerchantMatch(retailer: match)
                guard save() else { return }
                if match == nil { missed += 1 } else { found += 1 }
            } catch {
                if Task.isCancelled { return }
                retailerLookupSummary = "Retailer lookup stopped: \(error.localizedDescription)"
                return
            }
        }
        retailerLookupSummary = "Recognised \(found) retailers. \(missed) had no match."
        if visibleEntries.contains(where: { retailerMatch(for: $0) == nil }) {
            Task { await self.recogniseMerchants() }
        }
    }

    func addSource(_ provider: BankProvider) {
        guard !sources.contains(where: { $0.id == provider.id }) else { return }
        sources.append(provider); save(); loadBankStatus()
    }

    func provider(for entry: Entry) -> BankProvider? {
        guard let id = entry.providerID else { return nil }
        return sources.first(where: { $0.id == id }) ?? providers.first(where: { $0.id == id })
    }

    func setCategory(transactionID: String, category: Category, allFromMerchant: Bool) {
        entries = Categorisation.update(entries, transactionID: transactionID, category: category,
                                        allFromMerchant: allFromMerchant, rules: &merchantRules)
        save()
    }

    func removeRule(for entry: Entry) {
        merchantRules.removeValue(forKey: entry.merchantKey)
        save()
    }

    func setNotes(transactionID: String, notes: String) {
        guard let index = entries.firstIndex(where: { $0.id == transactionID }) else { return }
        let value = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        let updated: String? = value.isEmpty ? nil : value
        guard entries[index].notes != updated else { return }
        entries[index].notes = updated
        save()
    }

    func isRecurringMonthly(_ entry: Entry) -> Bool {
        let key = RecurringPayments.key(for: entry, merchantName: retailerName)
        return entries.contains { $0.recurringMonthly == true && RecurringPayments.key(for: $0, merchantName: retailerName) == key }
    }

    func setRecurringMonthly(_ entry: Entry, enabled: Bool) {
        guard !entry.isPending, entry.amount < 0 else { return }
        let key = RecurringPayments.key(for: entry, merchantName: retailerName)
        let previous = entries
        // One monthly series per merchant and account. Any payment in the series
        // can turn it off, including a newly synced payment with a different ID.
        for index in entries.indices where RecurringPayments.key(for: entries[index], merchantName: retailerName) == key {
            entries[index].recurringMonthly = enabled && entries[index].id == entry.id ? true : nil
        }
        if !save() { entries = previous }
    }

    @discardableResult
    func setReimbursement(transactionID: String, amount: Decimal) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == transactionID }),
              !amount.isNaN, amount >= 0,
              amount <= (entries[index].amount < 0 ? entries[index].magnitude : 0) else { return false }
        let updated: Decimal? = amount == 0 ? nil : amount
        guard entries[index].reimbursement != updated else { return true }
        entries[index].reimbursement = updated
        return save()
    }

    func prepareImport(_ url: URL) {
        do {
            importPreview = try readImport(url)
        } catch { message = error.localizedDescription }
    }

    func readImport(_ url: URL) throws -> CSVPreview {
        guard !isDemoSession else { throw CSVError.invalid("Turn off Demo Data in Settings before importing transactions.") }
        guard url.isFileURL else { throw CSVError.invalid("Choose a CSV file.") }
        let granted = url.startAccessingSecurityScopedResource()
        defer { if granted { url.stopAccessingSecurityScopedResource() } }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 5_000_000 else {
            throw CSVError.invalid("Choose a CSV smaller than 5 MB.")
        }
        let entries = try CSVImport.parse(String(contentsOf: url, encoding: .utf8))
            .map { Categorisation.apply(to: $0, rules: merchantRules) }
        return CSVPreview(entries: entries)
    }

    func commit(_ pending: [Entry]) {
        guard !isDemoSession else { return }
        if isDemo { entries = []; budgets = [:]; isDemo = false }
        var ids = Set(entries.map(\.id))
        let additions = pending.filter { ids.insert($0.id).inserted }
            .map { Categorisation.apply(to: $0, rules: merchantRules) }
        entries.append(contentsOf: additions)
        entries.sort { $0.date > $1.date }
        guard save() else { return }
        Task { await self.recogniseMerchants() }
        if message == nil { message = "Imported \(additions.count) transactions. Skipped \(pending.count - additions.count) duplicates." }
    }
}

@MainActor
final class BudgetSession: ObservableObject {
    @Published private(set) var store: BudgetStore
    init() { store = BudgetStore(isDemoSession: UserDefaults.standard.bool(forKey: "demoDataEnabled")) }
    func refreshSettings() {
        let demo = UserDefaults.standard.bool(forKey: "demoDataEnabled")
        guard demo != store.isDemoSession else { return }
        store = BudgetStore(isDemoSession: demo)
    }
}

@MainActor
private enum BackgroundBankRefresh {
    static let identifier = "com.personal.budgetr.bank-refresh"

    static func schedule(demo: Bool) {
        guard !demo else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
            return
        }
        let request = BGAppRefreshTaskRequest(identifier: identifier)
        request.earliestBeginDate = Date().addingTimeInterval(6 * 60 * 60)
        do { try BGTaskScheduler.shared.submit(request) }
        catch {
            Logger(subsystem: "com.personal.budgetr", category: "Background sync")
                .info("Background refresh was not scheduled: \(error.localizedDescription, privacy: .public)")
        }
    }
}

@main
struct BudgetApp: App {
    @StateObject private var session = BudgetSession()
    @StateObject private var appLock = AppLock()
    @Environment(\.scenePhase) private var scenePhase
    private var store: BudgetStore { session.store }
    var body: some Scene {
        WindowGroup {
            AppLockContainer(lock: appLock) {
                if let error = store.storageError {
                    VStack(spacing: 20) {
                        Image(systemName: "externaldrive.badge.exclamationmark").font(.largeTitle)
                        Text("Couldn't open saved data").font(.title2.weight(.semibold))
                        Text(error).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Try again") { store.openStorage() }.buttonStyle(.borderedProminent)
                    }.padding(28)
                } else {
                    RootView().environmentObject(store).environmentObject(appLock)
                        .id(ObjectIdentifier(store))
                }
            }.tint(ink).preferredColorScheme(.light)
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { session.refreshSettings() }
                    if phase == .background { BackgroundBankRefresh.schedule(demo: store.isDemoSession) }
                }
                .onAppear { BackgroundBankRefresh.schedule(demo: store.isDemoSession) }
                .onReceive(NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification)) { _ in
                    session.refreshSettings()
                }
        }
        .backgroundTask(.appRefresh(BackgroundBankRefresh.identifier)) {
            await refreshBanksInBackground()
        }
    }

    @MainActor
    private func refreshBanksInBackground() async {
        session.refreshSettings()
        BackgroundBankRefresh.schedule(demo: store.isDemoSession)
        guard !store.isDemoSession, store.pendingBankCallback == nil,
              store.authorisingBankID == nil, !Task.isCancelled else { return }
        if store.storageError != nil { store.openStorage() }
        // Structured work inherits the system task's expiration cancellation.
        await store.syncAllBanks(automatic: true)
    }
}

struct RootView: View {
    private struct Activity: Equatable {
        let ready: Bool
        let callback: URL?
        let syncing: Bool
    }
    @EnvironmentObject private var store: BudgetStore
    @EnvironmentObject private var appLock: AppLock
    @Environment(\.scenePhase) private var scenePhase
    @State private var selectedTab = 0
    @State private var pendingImportURL: URL?
    @State private var pendingImportHasAccess = false
    @StateObject private var syncPresentation = AccountSyncPresentation()
    var body: some View {
        TabView(selection: $selectedTab) {
            OverviewView().tabItem { Label("Overview", systemImage: "chart.pie.fill") }.tag(0)
            NavigationStack { TransactionsView() }.tabItem { Label("Transactions", systemImage: "arrow.left.arrow.right") }.tag(1)
            SourcesView().tabItem { Label("Accounts", systemImage: "building.columns") }.tag(2)
        }
        .environmentObject(syncPresentation)
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { syncPresentation.cancel() }
        }
        .task(id: Activity(ready: scenePhase == .active && !appLock.coversContent,
                           callback: store.pendingBankCallback, syncing: store.isBankSyncing)) {
            if scenePhase == .active && !appLock.coversContent && store.pendingBankCallback != nil {
                selectedTab = 2
                await Task { @MainActor in await store.completePendingBankAuthorisation() }.value
            }
        }
        .task(id: scenePhase == .active && !appLock.coversContent) {
            if scenePhase == .active && !appLock.coversContent {
                guard store.pendingBankCallback == nil, store.authorisingBankID == nil, !store.isBankSyncing else { return }
                if store.providers.isEmpty { await store.loadProviders() }
                store.refreshLogoCache(force: true)
                await syncPresentation.sync(store, automatic: true)
                await store.recogniseMerchants()
            }
        }
        .onOpenURL { url in
            if store.receiveBankCallback(url) { return }
            guard url.isFileURL else { return }
            releasePendingImport()
            pendingImportHasAccess = url.startAccessingSecurityScopedResource()
            pendingImportURL = url
            if !appLock.coversContent { openPendingImport() }
        }
        .onChange(of: appLock.coversContent) { _, covered in
            if !covered { openPendingImport() }
        }
        .onDisappear { releasePendingImport() }
        .sheet(item: $store.importPreview) { preview in ImportReviewView(entries: preview.entries) }
        .onAppear {
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--show-sources") { selectedTab = 2 }
            if ProcessInfo.processInfo.arguments.contains("--show-transactions") { selectedTab = 1 }
            #endif
        }
        .alert("Budget", isPresented: Binding(get: { store.message != nil }, set: { if !$0 { store.message = nil } })) {
            Button("OK") { store.message = nil }
        } message: { Text(store.message ?? "") }
    }
    private func openPendingImport() {
        guard let url = pendingImportURL else { return }
        selectedTab = 2
        store.prepareImport(url)
        releasePendingImport()
    }
    private func releasePendingImport() {
        if pendingImportHasAccess { pendingImportURL?.stopAccessingSecurityScopedResource() }
        pendingImportURL = nil
        pendingImportHasAccess = false
    }
}

private func money(_ amount: Decimal, _ currency: String = "GBP") -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .currency; formatter.currencyCode = currency
    formatter.locale = Locale(identifier: "en_GB")
    formatter.minimumFractionDigits = 2; formatter.maximumFractionDigits = 2
    return formatter.string(from: NSDecimalNumber(decimal: amount)) ?? "\(amount) \(currency)"
}

struct TransactionAmount: View {
    let entry: Entry
    var showsReimbursement = false
    private var adjusted: Bool { showsReimbursement && entry.reimbursedAmount > 0 }
    var body: some View {
        HStack(spacing: 6) {
            Text(money(entry.magnitude - (adjusted ? entry.reimbursedAmount : 0), entry.currency))
            .foregroundStyle(entry.category == .transfer ? Color.secondary
                             : entry.category == .income ? mutedIncome
                             : entry.amount > 0 ? moneyIn : ink)
            if adjusted {
                Text(money(entry.magnitude, entry.currency))
                    .strikethrough().foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(adjusted
            ? "Net spend \(money(entry.magnitude - entry.reimbursedAmount, entry.currency)), original amount \(money(entry.magnitude, entry.currency))"
            : "\(entry.amount > 0 ? "Money received" : entry.amount < 0 ? "Money spent" : "Zero amount"), \(money(entry.magnitude, entry.currency))")
    }
}

private struct OverviewBalancesView: View {
    @EnvironmentObject private var store: BudgetStore
    @ScaledMetric(relativeTo: .subheadline) private var tileWidth = 88.0
    @ScaledMetric(relativeTo: .subheadline) private var logoSize = 56.0

    private struct AccountItem: Identifiable {
        let provider: BankProvider
        let account: BankAccount
        var id: String { account.id }
    }
    private var accounts: [AccountItem] {
        store.sources.flatMap { provider in
            (store.bankAccounts[provider.id] ?? []).map { AccountItem(provider: provider, account: $0) }
        }
    }
    private var updatedText: String? {
        let providers = store.sources.filter { !(store.bankAccounts[$0.id] ?? []).isEmpty }
        let dates = providers.compactMap { store.bankSyncedAt[$0.id].flatMap { try? BankSync.date($0) } }
        guard dates.count == providers.count, let date = dates.min() else { return nil }
        if Calendar.current.isDateInToday(date) {
            return "Updated today, \(date.formatted(date: .omitted, time: .shortened))"
        }
        return "Updated \(date.formatted(date: .abbreviated, time: .shortened))"
    }
    var body: some View {
        let allAccounts = accounts
        let items = allAccounts.filter { $0.account.netBalance != 0 }
        let yonderBalance = ImportedAccountBalance.balance(entries: store.entries, account: "Yonder", currency: "GBP")
        let showYonder = store.entries.contains {
            $0.account == "Yonder" && ($0.id.hasPrefix("csv:") || $0.id.hasPrefix("yonder:"))
        }
        let summary = BankBalanceSummary(accounts: allAccounts.map(\.account), currency: "GBP", importedBalance: yonderBalance)
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Current balances.").font(.system(size: 32, weight: .regular, design: .serif)).foregroundStyle(ink)
                if let updatedText {
                    Text(updatedText).font(.caption).foregroundStyle(.secondary)
                        .accessibilityLabel("Oldest account balance update: \(updatedText)")
                }
            }
            ScrollView(.horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    totalTile(summary).frame(width: tileWidth)
                    ForEach(items) { item in
                        NavigationLink {
                            TransactionsView(idPrefix: item.account.id)
                        } label: {
                            accountTile(item).frame(width: tileWidth)
                        }.buttonStyle(.plain)
                    }
                    if showYonder {
                        NavigationLink {
                            YonderAccountView()
                        } label: {
                            yonderTile(balance: yonderBalance).frame(width: tileWidth)
                        }.buttonStyle(.plain)
                    }
                }.padding(.vertical, 8)
            }
            .scrollIndicators(.visible, axes: .horizontal)
            .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        }
    }
    private func yonderTile(balance: Decimal?) -> some View {
        VStack(spacing: 8) {
            BankLogo(provider: nil, fallback: "Y", size: logoSize).accessibilityHidden(true)
            Text(balance.map { money($0) } ?? "—")
                .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.65)
            if balance == nil {
                Text("Balance unavailable")
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
            }
        }.foregroundStyle(ink).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Yonder, \(balance.map { money($0) } ?? "Balance unavailable"), calculated from this month’s imported transactions")
            .accessibilityHint("View or import Yonder transactions")
    }
    private func totalTile(_ summary: BankBalanceSummary) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "sterlingsign")
                .font(.system(size: logoSize * 0.48, weight: .semibold))
                .foregroundStyle(.white).frame(width: logoSize, height: logoSize)
                .background(ink, in: Circle()).accessibilityHidden(true)
            Text(summary.total.map { money($0) } ?? "—")
                .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.65)
            Text("Total balance").font(.caption.weight(.medium)).lineLimit(2)
            if summary.total == nil {
                Text(summary.accountCount == 0 ? "No GBP accounts" : "Balance unavailable")
                    .font(.caption2).foregroundStyle(.secondary)
            }
        }.foregroundStyle(ink).multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
    }
    private func accountTile(_ item: AccountItem) -> some View {
        VStack(spacing: 8) {
            BankLogo(provider: item.provider, size: logoSize, accountKind: item.account.kind).accessibilityHidden(true)
            Text(item.account.netBalance.map { money($0, item.account.currency) } ?? "—")
                .font(.subheadline.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.65)
            Text(item.account.currentBalance == nil ? "Balance unavailable" : item.account.name)
                .font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        }.foregroundStyle(ink).multilineTextAlignment(.center)
            .frame(maxWidth: .infinity).contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(item.provider.name), \(item.account.name), \(item.account.netBalance.map { money($0, item.account.currency) } ?? "Balance unavailable")")
            .accessibilityHint("View transactions for this account")
    }
}

// Read the actual scroll offset for the fading hint. Refresh triggering belongs to
// the native refresh control, independent of SwiftUI layout/coordinate spaces.
private struct SyncScrollObserver: UIViewRepresentable {
    var onPull: (CGFloat) -> Void
    var onReachesTop: ((Bool) -> Void)? = nil

    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.onPull = onPull
        view.onReachesTop = onReachesTop
        DispatchQueue.main.async { [weak view] in view?.attach() }
    }
    static func dismantleUIView(_ view: Probe, coordinator: ()) { view.detach() }

    final class Probe: UIView {
        var onPull: ((CGFloat) -> Void)?
        var onReachesTop: ((Bool) -> Void)?
        private weak var scrollView: UIScrollView?
        private var observation: NSKeyValueObservation?
        private var foregroundObserver: NSObjectProtocol?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { detach() } else { attach() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            attach()
        }
        func attach() {
            if foregroundObserver == nil {
                foregroundObserver = NotificationCenter.default.addObserver(
                    forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.attach()
                        // Sync work is owned separately; release any native
                        // refresh control state left over from suspension.
                        self?.scrollView?.refreshControl?.endRefreshing()
                        self?.onPull?(0)
                    }
                }
            }
            var ancestor = superview
            while let view = ancestor {
                if let scroll = view as? UIScrollView {
                    scroll.refreshControl?.tintColor = .clear
                    guard scrollView !== scroll else { return }
                    observation?.invalidate()
                    scrollView = scroll
                    observation = scroll.observe(\.contentOffset, options: [.initial, .new]) { [weak self] scroll, _ in
                        let distance = max(0, -(scroll.contentOffset.y + scroll.adjustedContentInset.top))
                        DispatchQueue.main.async { [weak self, weak scroll] in
                            guard let self, let scroll, self.scrollView === scroll else { return }
                            scroll.refreshControl?.tintColor = .clear
                            self.onPull?(distance)
                            let top = self.convert(self.bounds, to: scroll).minY
                            self.onReachesTop?(top <= scroll.contentOffset.y + scroll.adjustedContentInset.top + 1)
                        }
                    }
                    return
                }
                ancestor = view.superview
            }
        }
        func detach() {
            observation?.invalidate()
            observation = nil
            scrollView = nil
            if let foregroundObserver { NotificationCenter.default.removeObserver(foregroundObserver) }
            foregroundObserver = nil
        }
    }
}

@MainActor
private final class AccountSyncPresentation: ObservableObject {
    @Published var isSyncing = false
    @Published var result: String?
    @Published var hadErrors = false
    @Published var details: String?
    @Published var resultID = UUID()

    private var syncTask: Task<Void, Never>?
    private var dismissalTask: Task<Void, Never>?

    func start(_ store: BudgetStore) {
        guard syncTask == nil, !isSyncing, !store.isBankSyncing else { return }
        syncTask = Task { @MainActor in
            await sync(store)
            syncTask = nil
        }
    }

    func cancel() { syncTask?.cancel() }

    func sync(_ store: BudgetStore, automatic: Bool = false) async {
        if store.isDemoSession {
            if automatic { return }
            finish("Demo data · bank syncing is off", hadErrors: false)
            return
        }
        guard !isSyncing, !store.isBankSyncing else { return }
        dismissalTask?.cancel()
        details = nil
        if let error = store.storageError {
            finish(error, hadErrors: true)
            return
        }
        guard !store.bankCredentialIDs.isEmpty else {
            if !automatic { finish("Connect a bank in Accounts to sync.", hadErrors: true) }
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            result = nil
            details = nil
            isSyncing = true
        }
        defer { isSyncing = false }
        let attempted = await store.syncAllBanks(automatic: automatic)
        guard !Task.isCancelled else { result = nil; return }
        guard attempted || !automatic else { return }
        let lines = store.bankSyncSummary?.components(separatedBy: "\n") ?? []
        details = lines.count > 1 ? lines.dropFirst().joined(separator: "\n") : nil
        finish(lines.first ?? "Unable to sync. Please try again.",
               hadErrors: lines.isEmpty || lines.count > 1 || !(lines.first?.hasPrefix("Synced ") ?? false))
    }

    private func finish(_ message: String, hadErrors: Bool) {
        withAnimation(.easeInOut(duration: 0.2)) {
            isSyncing = false
            self.hadErrors = hadErrors
            result = message
            resultID = UUID()
        }
        dismissalTask?.cancel()
        dismissalTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            withAnimation(.easeOut(duration: 0.4)) { self?.result = nil }
        }
    }
}

private struct AccountSyncStatus: View {
    @EnvironmentObject private var store: BudgetStore
    @ObservedObject var presentation: AccountSyncPresentation
    var pullDistance: CGFloat = 0
    var alwaysVisible = false
    @State private var showingDetails = false

    private var isSyncing: Bool { presentation.isSyncing || store.isBankSyncing }

    private var message: String {
        if isSyncing {
            if let id = store.busyBank, let bank = store.sources.first(where: { $0.id == id }) {
                return "Syncing \(bank.name)…"
            }
            return "Syncing accounts…"
        }
        return presentation.result ?? "Pull down to sync"
    }

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                if isSyncing {
                    ProgressView().controlSize(.small).tint(ink)
                } else {
                    Image(systemName: presentation.result == nil ? "arrow.down"
                          : presentation.hadErrors ? "exclamationmark.circle" : "checkmark.circle")
                }
                Text(message)
            }
            .id(message)
            .transition(.opacity)
            .frame(maxWidth: .infinity)
            if presentation.result != nil, presentation.details != nil {
                Button("View details") { showingDetails = true }.buttonStyle(.plain)
            }
        }
        .font(.caption).foregroundStyle(ink)
        .multilineTextAlignment(.center)
        .padding(.horizontal, 22).padding(.vertical, 12)
        .background(paper, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .opacity(alwaysVisible || isSyncing || presentation.result != nil ? 1 : min(pullDistance / 65, 1))
        .allowsHitTesting(presentation.result != nil && presentation.details != nil)
        .accessibilityHidden(!alwaysVisible && !isSyncing && presentation.result == nil)
        .accessibilityAction(named: Text("Sync accounts")) { presentation.start(store) }
        .alert("Sync details", isPresented: $showingDetails) {
            Button("Done", role: .cancel) { }
        } message: { Text(presentation.details ?? "") }
    }
}

struct OverviewView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var month = Date()
    @State private var editingBudgets = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var movingForward = true
    @State private var currentDate = Date()
    @State private var pullDistance: CGFloat = 0
    @EnvironmentObject private var syncPresentation: AccountSyncPresentation
    @Environment(\.scenePhase) private var scenePhase
    private var total: Decimal { Category.spending.reduce(0) { $0 + store.budgets[$1.rawValue, default: 0] } }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 0) {
                    OverviewBalancesView()
                        .padding(.horizontal, 22).padding(.top, 8)
                    ZStack {
                        monthPage(month)
                            .id(month)
                            .transition(reduceMotion ? .opacity : .asymmetric(
                                insertion: .move(edge: movingForward ? .trailing : .leading),
                                removal: .move(edge: movingForward ? .leading : .trailing)
                            ))
                    }
                    .clipped()
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 30)
                            .onEnded { gesture in
                                let horizontal = gesture.translation.width
                                let vertical = gesture.translation.height
                                guard abs(horizontal) >= 50, abs(horizontal) > abs(vertical) * 1.5 else { return }
                                moveMonth(horizontal < 0 ? 1 : -1)
                            }
                    )
                }
                .background(SyncScrollObserver { pullDistance = $0 })
            }
            .scrollBounceBehavior(.always)
            .refreshable {
                // Release the native refresh inset immediately. Progress lives
                // in the navigation bar, so syncing must not hold content down.
                syncPresentation.start(store)
            }
            .accessibilityAction(named: Text("Sync accounts")) { syncPresentation.start(store) }
            .background(paper)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    AccountSyncStatus(presentation: syncPresentation, pullDistance: pullDistance)
                        .frame(maxWidth: 300)
                }
            }
            .sheet(isPresented: $editingBudgets) { BudgetEditingView(budgets: store.budgets) }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                currentDate = Date()
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { currentDate = Date() }
            }
        }
    }
    private func monthPage(_ month: Date) -> some View {
        let expected = RecurringPayments.outstanding(store.visibleEntries, month: month, now: currentDate, merchantName: store.retailerName)
            .filter { $0.currency == "GBP" }
        let recurring = expected.reduce(Decimal.zero) { $0 + $1.magnitude - $1.reimbursedAmount }
        let actual = BudgetMath.spending(store.visibleEntries, currency: "GBP", month: month)
        let spent = actual + recurring
        let confirmed = BudgetMath.spending(store.visibleEntries, currency: "GBP", month: month, includePending: false)
        return VStack(alignment: .leading, spacing: 24) {
            if store.isDemo {
                Label(store.isDemoSession ? "Demo data" : "Demo data · your bank data is not synced yet", systemImage: "sparkles")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22)
            }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Monthly spend.").font(.system(size: 32, weight: .regular, design: .serif))
                        .layoutPriority(1)
                    Spacer(minLength: 0)
                    Text(month.formatted(.dateTime.month(.wide).year()).uppercased())
                        .font(.caption.weight(.semibold)).tracking(1.4).multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }.padding(.horizontal, 22)
                Divider().overlay(.white.opacity(0.3)).padding(.horizontal, 22)
                HStack(spacing: 4) {
                    monthNavigationButton(-1)
                    VStack(alignment: .leading, spacing: 14) {
                        Text("SPENT THIS MONTH").font(.caption.weight(.semibold)).tracking(1.4)
                        Text(money(spent)).font(.system(size: 42, weight: .medium, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                            .foregroundStyle(.white)
                        if actual != confirmed || recurring > 0 {
                            Text("Includes \(money(actual - confirmed)) pending, \(money(recurring)) upcoming bills")
                                .font(.caption).foregroundStyle(.white.opacity(0.75))
                        }
                        if total > 0 {
                            Text(total >= spent ? "\(money(total - spent)) left in your budget" : "\(money(spent - total)) over your budget").font(.subheadline)
                                .foregroundStyle(spent > total ? overBudget : .white)
                            SpendingProgress(spent: spent, confirmed: confirmed, budget: total, color: spent > total ? overBudget : .white)
                        } else { Text("Tap Edit beside Budget view to set your budget.").font(.subheadline) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    monthNavigationButton(1)
                }
            }
            .padding(.vertical, 26).foregroundStyle(.white).frame(maxWidth: .infinity, alignment: .leading)
            .background(ink)
            HStack {
                Text("Budget.").font(.system(size: 32, weight: .regular, design: .serif)).foregroundStyle(ink)
                Spacer()
                Button { editingBudgets = true } label: {
                    Text("EDIT").font(.caption.weight(.semibold)).tracking(1.4)
                        .foregroundStyle(ink)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityLabel("Edit category budgets")
            }.padding(.horizontal, 22)
            VStack(spacing: 20) {
                ForEach(Category.spending, id: \.self) { category in
                    NavigationLink {
                        TransactionsView(categoryFilter: category, monthFilter: month)
                    } label: {
                        let reserved = expected.filter { $0.category == category }.reduce(Decimal.zero) { $0 + $1.magnitude - $1.reimbursedAmount }
                        let used = BudgetMath.spending(store.visibleEntries, currency: "GBP", month: month, category: category) + reserved
                        let confirmed = BudgetMath.spending(store.visibleEntries, currency: "GBP", month: month, category: category, includePending: false)
                        let limit = store.budgets[category.rawValue, default: 0]
                        HStack(spacing: 14) {
                            Image(systemName: category.symbol).symbolVariant(.none).foregroundStyle(category.color).frame(width: 42, height: 42).background(paper, in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 7) {
                                Text(category.rawValue).font(.subheadline.weight(.medium))
                                HStack(alignment: .firstTextBaseline, spacing: 8) {
                                    Text(money(used)).font(.subheadline.monospacedDigit())
                                        .accessibilityLabel("\(money(used)) spent")
                                    Spacer(minLength: 0)
                                    if limit > 0 {
                                        (Text(used > limit
                                              ? "\(money(used - limit)) over"
                                              : "\(money(limit - used)) left")
                                            .foregroundColor(used > limit ? overBudget : .secondary)
                                         + Text(" / \(money(limit))").foregroundColor(.secondary))
                                            .font(.caption.monospacedDigit())
                                    } else {
                                        Text("No budget set").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                if limit > 0 { SpendingProgress(spent: used, confirmed: confirmed, budget: limit, color: used > limit ? overBudget : ink) }
                            }
                        }.foregroundStyle(ink)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }.buttonStyle(HighlightedRowStyle())
                }
            }.padding(20).background(.white, in: RoundedRectangle(cornerRadius: 24))
                .padding(.horizontal, 22)
            Text("Budgets are recurring monthly limits in GBP. Transfers, savings and income are excluded.").font(.caption).foregroundStyle(.secondary)
                .padding(.horizontal, 22)
        }.padding(.vertical, 22)
    }
    private var availableMonths: [Date] {
        OverviewMonths.available(entries: store.entries, now: currentDate)
    }
    private func adjacentMonth(_ offset: Int) -> Date? {
        let start = Calendar.current.dateInterval(of: .month, for: month)!.start
        return offset < 0 ? availableMonths.last(where: { $0 < start })
            : availableMonths.first(where: { $0 > start })
    }
    private func monthNavigationButton(_ offset: Int) -> some View {
        let disabled = adjacentMonth(offset) == nil
        return Button { moveMonth(offset) } label: {
            Image(systemName: offset < 0 ? "chevron.left" : "chevron.right")
                .font(.body.weight(.medium)).foregroundStyle(.white)
                .frame(width: 44, height: 44).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(offset < 0 ? "Previous month" : "Next month")
        .disabled(disabled).opacity(disabled ? 0.35 : 1)
    }
    private func moveMonth(_ offset: Int) {
        guard let nextMonth = adjacentMonth(offset) else { return }
        movingForward = offset > 0
        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .easeInOut(duration: 0.3)) {
            month = nextMonth
        }
    }
}

/// A single budget bar: confirmed spending is solid, pending spending is paler.
private struct SpendingProgress: View {
    let spent: Decimal
    let confirmed: Decimal
    let budget: Decimal
    let color: Color

    var body: some View {
        let fractions = BudgetMath.progress(spent: spent, confirmed: confirmed, budget: budget)
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                HStack(spacing: 0) {
                    Rectangle().fill(color).frame(width: geometry.size.width * fractions.confirmed)
                    Rectangle().fill(color.opacity(0.45)).frame(width: geometry.size.width * fractions.pending)
                }
            }.clipShape(Capsule())
        }
        .frame(height: 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(money(confirmed)) confirmed, \(money(spent - confirmed)) pending, \(money(budget)) budget")
    }
}

struct BudgetEditingView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State private var amounts: [String: String]
    @State private var validationError: String?
    private var totalBudget: Decimal? {
        var total = Decimal.zero
        for category in Category.spending {
            let text = amounts[category.rawValue, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Decimal(string: text.isEmpty ? "0" : text, locale: Locale.current),
                  !value.isNaN, value >= 0 else { return nil }
            total += value
        }
        return total
    }

    init(budgets: [String: Decimal]) {
        _amounts = State(initialValue: Dictionary(uniqueKeysWithValues: Category.spending.map {
            ($0.rawValue, NSDecimalNumber(decimal: budgets[$0.rawValue, default: 0]).stringValue)
        }))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Category.spending, id: \.self) { category in
                        HStack {
                            CategoryLabel(category: category)
                            Spacer()
                            Text("£").foregroundStyle(.secondary)
                            TextField("0", text: Binding(
                                get: { amounts[category.rawValue, default: ""] },
                                set: { amounts[category.rawValue] = $0 }
                            ))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                            .frame(width: 100).accessibilityLabel("\(category.rawValue) monthly budget in pounds")
                        }
                    }
                } footer: {
                    Text("Recurring monthly limits in GBP. Set a category to zero to leave it without a budget.")
                }
            }
            .scrollContentBackground(.hidden).background(paper)
            .navigationTitle("Edit budgets").navigationBarTitleDisplayMode(.inline)
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Text("Total budget").font(.headline)
                    Spacer()
                    Text(totalBudget.map { money($0) } ?? "—")
                        .font(.headline.monospacedDigit())
                }
                .foregroundStyle(ink)
                .padding(.horizontal, 20).padding(.vertical, 16)
                .background(paper)
                .overlay(alignment: .top) { Divider() }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { saveBudgets() } }
            }
            .alert("Check budget amounts", isPresented: Binding(
                get: { validationError != nil }, set: { if !$0 { validationError = nil } }
            )) { Button("OK") { validationError = nil } } message: { Text(validationError ?? "") }
        }
    }

    private func saveBudgets() {
        var budgets = store.budgets
        for category in Category.spending {
            let text = amounts[category.rawValue, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            guard let value = Decimal(string: text.isEmpty ? "0" : text, locale: Locale.current), !value.isNaN, value >= 0 else {
                validationError = "Enter an amount of zero or more for \(category.rawValue)."
                return
            }
            budgets[category.rawValue] = value
        }
        store.budgets = budgets
        if store.save() { dismiss() }
    }
}

struct TransactionRow: View {
    let entry: Entry
    @EnvironmentObject private var store: BudgetStore
    @ScaledMetric(relativeTo: .caption) private var accountNameWidth = 120.0
    private var textColor: Color {
        entry.category == .transfer || entry.category == .income ? .secondary : ink
    }
    var body: some View {
        let retailer = store.retailer(for: entry)
        HStack(spacing: 14) {
            RetailerArtwork(retailer: retailer, fallback: entry.category.symbol, size: 42, fallbackColor: entry.category.color)
                .overlay(alignment: .bottomTrailing) {
                    if retailer?.logoURL != nil || retailer?.customIconData != nil {
                    Image(systemName: entry.category.symbol)
                        .font(.system(size: 11, weight: .medium))
                        .symbolVariant(.none)
                        .foregroundStyle(entry.category.color)
                        .frame(width: 20, height: 20)
                        .background(paper, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2)).offset(x: 5, y: 5)
                        .accessibilityLabel(entry.category.rawValue)
                    }
                }
            VStack(alignment: .leading, spacing: 5) {
                Text(store.retailerName(for: entry)).font(.subheadline.weight(.medium))
                    .foregroundStyle(textColor).lineLimit(2).truncationMode(.tail)
                if let notes = entry.notes, !notes.isEmpty {
                    Text(notes).font(.caption).italic().foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 5) {
                TransactionAmount(entry: entry, showsReimbursement: true).font(.subheadline.monospacedDigit())
                    .fixedSize(horizontal: true, vertical: false)
                HStack(spacing: 5) {
                    Text(entry.account).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.tail)
                    BankLogo(provider: store.provider(for: entry), fallback: entry.account == "Yonder" ? "Y" : "B", size: 16, accountKind: entry.bankAccountKind)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: accountNameWidth, alignment: .trailing)
            }
        }.padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
    }
}

struct TransactionsView: View {
    @EnvironmentObject private var syncPresentation: AccountSyncPresentation
    var accountFilter: String? = nil
    var idPrefix: String? = nil
    var categoryFilter: Category? = nil
    var monthFilter: Date? = nil
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var search = ""
    @State private var selectedEntry: Entry?
    @State private var selectedAccount: String?
    @State private var showingAccounts = false
    @State private var showingSearch = false
    @State private var shouldFocusSearch = false
    @FocusState private var searchFocused: Bool
    private var canSelectAccount: Bool { accountFilter == nil && idPrefix == nil }
    private var linkedAccount: (provider: BankProvider, account: BankAccount)? {
        guard let idPrefix else { return nil }
        for provider in store.sources {
            if let account = store.bankAccounts[provider.id]?.first(where: { $0.id == idPrefix }) {
                return (provider, account)
            }
        }
        return nil
    }
    private var heading: String {
        let title = categoryFilter?.rawValue ?? "Transactions"
        return title.hasSuffix(".") ? title : title + "."
    }
    private var fixedAccountName: String {
        if let linkedAccount {
            let name = linkedAccount.account.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? linkedAccount.provider.name : name
        }
        if let accountFilter { return accountFilter }
        if let idPrefix, let entry = store.entries.first(where: { $0.id.hasPrefix(idPrefix) }) {
            return entry.account
        }
        return "Account"
    }
    private var emptyDescription: String {
        if categoryFilter != nil { return "No transactions in this category for the selected month, or matching your search." }
        if accountFilter == "Yonder" { return "Tap Import to add a CSV, or adjust your search." }
        return "Import a CSV from Accounts → Yonder, or adjust your search."
    }
    private func accountLabel(_ account: String?, compact: Bool = false, provider: BankProvider? = nil) -> some View {
        HStack(spacing: 8) {
            if let account {
                let entry = store.visibleEntries.first {
                    $0.account == account && (idPrefix == nil || $0.id.hasPrefix(idPrefix!)) && $0.providerID != nil
                }
                BankLogo(provider: provider ?? entry.flatMap { store.provider(for: $0) },
                         fallback: account == "Yonder" ? "Y" : "B", size: 24,
                         accountKind: linkedAccount?.account.kind ?? entry?.bankAccountKind)
                    .allowsHitTesting(false).accessibilityHidden(true)
            } else {
                Image(systemName: "building.columns").frame(width: 24, height: 24)
            }
            Text(compact ? (account ?? "All accounts").uppercased() : account ?? "All accounts")
                .font(compact ? .caption.weight(.semibold) : .subheadline)
                .tracking(compact ? 1.4 : 0)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private var accounts: [String] {
        Set(store.visibleEntries.filter { idPrefix == nil || $0.id.hasPrefix(idPrefix!) }.map(\.account))
            .union(store.offlineAccounts)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
    private var filtered: [Entry] {
        store.visibleEntries.filter {
            (idPrefix == nil || $0.id.hasPrefix(idPrefix!)) &&
            (accountFilter == nil || $0.account == accountFilter) &&
            (selectedAccount == nil || $0.account == selectedAccount) &&
            (categoryFilter == nil || $0.category == categoryFilter) &&
            (monthFilter == nil || Calendar.current.isDate($0.date, equalTo: monthFilter!, toGranularity: .month)) &&
            (search.isEmpty || store.retailerName(for: $0).localizedCaseInsensitiveContains(search)
             || $0.description.localizedCaseInsensitiveContains(search)
             || $0.account.localizedCaseInsensitiveContains(search)
             || ($0.notes?.localizedCaseInsensitiveContains(search) ?? false))
        }
    }
    var body: some View {
        Group {
            List {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(heading)
                            .font(.system(size: 32, weight: .regular, design: .serif))
                            .foregroundStyle(ink).accessibilityAddTraits(.isHeader)
                            .layoutPriority(1)
                        if categoryFilter != nil, let monthFilter {
                            Spacer(minLength: 0)
                            Text(monthFilter.formatted(.dateTime.month(.wide).year()).uppercased())
                                .font(.caption.weight(.semibold)).tracking(1.4)
                                .foregroundStyle(ink).multilineTextAlignment(.trailing)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    if canSelectAccount {
                        accountControls
                    } else {
                        accountLabel(fixedAccountName, compact: true, provider: linkedAccount?.provider)
                            .foregroundStyle(ink)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                            .accessibilityElement(children: .combine)
                    }
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if filtered.isEmpty {
                    ContentUnavailableView("No transactions", systemImage: "tray", description: Text(emptyDescription))
                }
                if filtered.contains(where: \.isPending) {
                    Section {
                        ForEach(filtered.filter(\.isPending)) { entry in
                            Button { selectedEntry = entry } label: { TransactionRow(entry: entry) }
                                .buttonStyle(HighlightedRowStyle()).foregroundStyle(ink)
                        }
                    } header: {
                        HStack(spacing: 12) {
                            Text("Pending")
                                .font(.caption.weight(.semibold)).foregroundStyle(ink)
                            Rectangle().fill(ink.opacity(0.15)).frame(height: 1)
                        }.textCase(nil).padding(.vertical, 6)
                    }
                }
                ForEach(TransactionGrouping.days(filtered.filter { !$0.isPending })) { day in
                    Section {
                        ForEach(day.entries) { entry in
                            Button { selectedEntry = entry } label: { TransactionRow(entry: entry) }
                                .buttonStyle(HighlightedRowStyle()).foregroundStyle(ink)
                        }
                    } header: {
                        HStack(spacing: 12) {
                            Text(day.date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()))
                                .font(.caption.weight(.semibold)).foregroundStyle(ink)
                            Rectangle().fill(ink.opacity(0.15)).frame(height: 1)
                        }.textCase(nil).padding(.vertical, 6)
                    }
                }
            }.listSectionSpacing(16).scrollContentBackground(.hidden).background(paper)
                .contentMargins(.horizontal, 22, for: .scrollContent)
                .contentMargins(.top, 0, for: .scrollContent)
                .overlay(alignment: .top) {
                    if showingSearch {
                        searchField
                            .background(paper, in: RoundedRectangle(cornerRadius: 10))
                            .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
                            .padding(.horizontal, 22)
                            .padding(.top, 8)
                            .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                            .onAppear {
                                if shouldFocusSearch {
                                    searchFocused = true
                                    shouldFocusSearch = false
                                }
                            }
                    }
                }
                .navigationTitle("")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar(.visible, for: .navigationBar)
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        AccountSyncStatus(presentation: syncPresentation)
                            .frame(maxWidth: 260)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            if showingSearch {
                                searchFocused = false
                                shouldFocusSearch = false
                                search = ""
                                withAnimation(.easeInOut(duration: 0.22)) { showingSearch = false }
                            } else {
                                shouldFocusSearch = true
                                withAnimation(.easeInOut(duration: 0.22)) { showingSearch = true }
                            }
                        } label: {
                            Label(showingSearch ? "Close search" : "Search transactions",
                                  systemImage: showingSearch ? "xmark" : "magnifyingglass")
                        }
                    }
                }
                .onChange(of: accounts) { _, accounts in
                    if let selectedAccount, !accounts.contains(selectedAccount) { self.selectedAccount = nil }
                }
                .scrollDismissesKeyboard(.interactively)
                .sheet(item: $selectedEntry) { entry in TransactionDetailView(entry: entry).environmentObject(store) }
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--show-transaction-detail") { selectedEntry = filtered.sorted { $0.date > $1.date }.first }
                    #endif
                }
        }
    }
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("Merchant, account or notes", text: $search)
                .font(.body).foregroundStyle(ink)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .submitLabel(.search).focused($searchFocused)
                .onSubmit { searchFocused = false }
                .accessibilityLabel("Search transactions")
            if !search.isEmpty {
                Button { search = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }.buttonStyle(.plain).accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 44)
        .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10))
    }
    private var accountControls: some View {
        Button {
            searchFocused = false
            showingAccounts = true
        } label: {
            HStack(spacing: 6) {
                accountLabel(selectedAccount, compact: true)
                Spacer(minLength: 8)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .foregroundStyle(ink)
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account, \(selectedAccount ?? "All accounts")")
        .popover(isPresented: $showingAccounts, arrowEdge: .top) {
            ScrollView {
                VStack(spacing: 0) {
                    accountOption(nil)
                    ForEach(accounts, id: \.self) { account in
                        accountOption(account)
                    }
                }
                .padding(8)
            }
            .frame(width: 300, height: CGFloat(min(accounts.count + 1, 7)) * 48 + 16)
            .presentationCompactAdaptation(.popover)
        }
    }
    private func accountOption(_ account: String?) -> some View {
        Button {
            selectedAccount = account
            showingAccounts = false
        } label: {
            HStack {
                accountLabel(account)
                Spacer()
                if selectedAccount == account {
                    Image(systemName: "checkmark").font(.subheadline.weight(.semibold))
                }
            }
            .font(.subheadline).foregroundStyle(ink)
            .padding(.horizontal, 8).frame(minHeight: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selectedAccount == account ? .isSelected : [])
    }
}

struct TransactionDetailView: View {
    let transactionID: String
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @State private var notes: String
    @State private var reimbursement: String
    @State private var reimbursementError: String?
    @State private var pendingCategory: Category?
    @State private var confirmingCategory = false
    @State private var editingMerchant = false
    private var entry: Entry? { store.visibleEntries.first(where: { $0.id == transactionID }) }
    private var matchCount: Int {
        guard let entry else { return 0 }
        return store.visibleEntries.filter { $0.merchantKey == entry.merchantKey }.count
    }

    init(entry: Entry) {
        transactionID = entry.id
        _notes = State(initialValue: entry.notes ?? "")
        _reimbursement = State(initialValue: entry.reimbursement.map { $0.formatted(.number.grouping(.never)) } ?? "")
    }

    private func applyCategory(allFromMerchant: Bool) {
        guard let category = pendingCategory, entry != nil else { return }
        store.setCategory(transactionID: transactionID, category: category, allFromMerchant: allFromMerchant)
        pendingCategory = nil
    }

    private func sectionHeading(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.caption.weight(.semibold)).tracking(1.4).foregroundStyle(ink)
    }

    private func informationField(_ title: String, value: String, inline: Bool = false, valueColor: Color = ink) -> some View {
        Group {
            if inline {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(value)
                        .foregroundStyle(valueColor)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    sectionHeading(title)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text(value).foregroundStyle(valueColor).fixedSize()
                        Spacer(minLength: 0)
                        sectionHeading(title).fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        sectionHeading(title)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                            .multilineTextAlignment(.trailing)
                        Text(value)
                            .foregroundStyle(valueColor)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value)")
    }

    @discardableResult
    private func saveReimbursement() -> Bool {
        guard let entry else { return false }
        guard !entry.isPending, entry.amount < 0 else { return true }
        do {
            let value = try entry.validatedReimbursement(reimbursement)
            guard store.setReimbursement(transactionID: transactionID, amount: value) else {
                reimbursementError = "The reimbursement could not be saved. Please try again."
                return false
            }
            reimbursementError = nil
            return true
        } catch {
            reimbursementError = error.localizedDescription
            return false
        }
    }

    var body: some View {
        NavigationStack {
            if let entry {
                List {
                    Section {
                        VStack(spacing: 12) {
                            RetailerArtwork(retailer: store.retailer(for: entry), fallback: entry.category.symbol, size: 72, fallbackColor: entry.category.color)
                                .overlay(alignment: .topTrailing) {
                                    Button { editingMerchant = true } label: {
                                        Image(systemName: "pencil")
                                            .font(.system(size: 16, weight: .semibold)).foregroundStyle(.black)
                                            .frame(width: 36, height: 36)
                                            .background(Color(uiColor: .systemGray5), in: Circle())
                                            .overlay(Circle().strokeBorder(paper, lineWidth: 3))
                                            .frame(width: 44, height: 44)
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Edit merchant name and icon")
                                    .offset(x: 22, y: -22)
                                }
                            Text(store.retailerName(for: entry))
                                .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                            TransactionAmount(entry: entry).font(.system(size: 36, weight: .medium, design: .rounded))
                            HStack(spacing: 6) {
                                BankLogo(provider: store.provider(for: entry), fallback: entry.account == "Yonder" ? "Y" : "B", size: 20, accountKind: entry.bankAccountKind)
                                    .accessibilityHidden(true)
                                Text(entry.account).font(.subheadline).foregroundStyle(.secondary)
                            }
                        }.frame(maxWidth: .infinity).padding(.vertical, 12)
                    }.listRowBackground(Color.clear)
                    if entry.isPending {
                        Text("Pending transaction")
                            .font(.subheadline).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .listRowBackground(Color.clear)
                    }
                        Section {
                            Menu {
                                Picker("Category", selection: Binding(
                                    get: { entry.category },
                                    set: { selected in
                                        guard selected != entry.category else { return }
                                        pendingCategory = selected
                                        confirmingCategory = true
                                    }
                                )) {
                                    ForEach(Category.allCases, id: \.self) { value in
                                        CategoryLabel(category: value).tag(value)
                                    }
                                }
                            } label: {
                                HStack {
                                    CategoryLabel(category: entry.category)
                                    Spacer(minLength: 8)
                                    Image(systemName: "chevron.up.chevron.down").font(.caption.weight(.semibold))
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .accessibilityLabel("Category, \(entry.category.rawValue)")
                        } header: { sectionHeading("Category") }
                    if !entry.isPending {
                        if entry.amount < 0 && (Category.spending.contains(entry.category) || store.isRecurringMonthly(entry)) {
                            Section {
                                Toggle("Recurring monthly", isOn: Binding(
                                    get: { store.isRecurringMonthly(entry) },
                                    set: { store.setRecurringMonthly(entry, enabled: $0) }
                                ))
                                .tint(ink)
                            } footer: {
                                Text("Reserve the latest payment amount in each month’s budget until a payment to this merchant appears on this account.")
                            }
                        }
                        if entry.amount < 0 {
                            Section {
                                HStack {
                                    Text(entry.currency == "GBP" ? "£" : entry.currency).foregroundStyle(.secondary)
                                    TextField("0.00", text: $reimbursement)
                                        .keyboardType(.decimalPad)
                                        .accessibilityLabel("Reimbursed amount in \(entry.currency)")
                                    Button {
                                        reimbursement = entry.magnitude.formatted(.number.grouping(.never))
                                        saveReimbursement()
                                    } label: {
                                        Text("FULL AMOUNT").font(.caption.weight(.semibold)).tracking(1.4)
                                            .foregroundStyle(ink)
                                            .padding(.horizontal, 12).padding(.vertical, 8)
                                            .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                                    }
                                    .buttonStyle(.borderless)
                                    .fixedSize(horizontal: true, vertical: false)
                                }
                                if let reimbursementError {
                                    Text(reimbursementError).font(.caption).foregroundStyle(overBudget)
                                }
                            } header: { sectionHeading("Reimbursement") } footer: {
                                Text("The reimbursed amount is deducted from spending in this transaction’s month. Clear it to remove the reimbursement.")
                            }
                            .task(id: reimbursement) {
                                do {
                                    try await Task.sleep(for: .milliseconds(500))
                                    saveReimbursement()
                                } catch { }
                            }
                        }
                        Section {
                            TextField("Add a note…", text: $notes, axis: .vertical)
                                .lineLimit(3...6)
                                .onSubmit { store.setNotes(transactionID: transactionID, notes: notes) }
                                .task(id: notes) {
                                    do {
                                        try await Task.sleep(for: .milliseconds(500))
                                        store.setNotes(transactionID: transactionID, notes: notes)
                                    } catch { }
                                }
                        } header: { sectionHeading("Notes") }
                    }
                    Section {
                        informationField("Date", value: entry.date.formatted(date: .long, time: .shortened), inline: true)
                        informationField("Merchant", value: entry.merchant)
                        informationField("Description", value: entry.description)
                    } header: { sectionHeading("Transaction details") }
                    Section {
                        let summary = MerchantSummary(entries: store.entries,
                            merchantName: store.retailerName(for: entry), displayName: { store.retailerName(for: $0) })
                        informationField("Transactions", value: summary.transactionCount.formatted(), inline: true)
                        ForEach(summary.currencies) { totals in
                            let suffix = summary.currencies.count > 1 ? " · \(totals.currency)" : ""
                            let received = totals.totalSpend < 0
                            let color = received ? mutedIncome : ink
                            informationField("Average transaction" + suffix,
                                             value: money(received ? -totals.averageTransaction : totals.averageTransaction, totals.currency),
                                             inline: true, valueColor: color)
                            informationField((received ? "Total received" : "Total spent") + suffix,
                                             value: money(received ? -totals.totalSpend : totals.totalSpend, totals.currency),
                                             inline: true, valueColor: color)
                        }
                    } header: { sectionHeading("Merchant summary") }
                    if !entry.isPending {
                        if let rule = store.merchantRules[entry.merchantKey] {
                            Section {
                                HStack(spacing: 12) {
                                    CategoryLabel(category: rule)
                                    Spacer(minLength: 8)
                                    Button(role: .destructive) { store.removeRule(for: entry) } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.body)
                                            .foregroundStyle(.secondary)
                                            .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.borderless)
                                    .fixedSize(horizontal: true, vertical: false)
                                    .accessibilityLabel("Remove merchant rule")
                                }
                            } header: { sectionHeading("Merchant rule")
                            } footer: { Text("Removing the rule stops it applying to future imports. Existing categories stay as they are.") }
                        }
                    }
                }.scrollContentBackground(.hidden).background(paper)
                    .navigationTitle("Transaction details").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Done") {
                                if !entry.isPending {
                                    guard saveReimbursement() else { return }
                                    store.setNotes(transactionID: transactionID, notes: notes)
                                }
                                dismiss()
                            }
                        }
                    }
                    .onDisappear {
                        guard !entry.isPending else { return }
                        if (try? entry.validatedReimbursement(reimbursement)) != nil { saveReimbursement() }
                        store.setNotes(transactionID: transactionID, notes: notes)
                    }
                    .sheet(isPresented: $editingMerchant) {
                        NavigationStack {
                            let rule = MerchantMatchingRule.forEditing(entry: entry, matches: store.merchantMatches,
                                                                       displayName: store.retailerName(for: entry))
                            CustomRetailerView(entry: entry, retailer: store.retailer(for: entry),
                                               displayName: store.retailerName(for: entry),
                                               matchingPattern: rule?.match.matchingPattern ?? "",
                                               matchDescription: rule?.match.matchDescription == true,
                                               ruleOwner: rule?.owner) {
                                editingMerchant = false
                            }
                            .toolbar {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel") { editingMerchant = false }
                                }
                            }
                        }
                    }
                    .alert("Apply \(pendingCategory?.rawValue ?? "category")?", isPresented: $confirmingCategory) {
                        Button("Just this transaction") { applyCategory(allFromMerchant: false) }
                        Button("All from this merchant") { applyCategory(allFromMerchant: true) }
                        Button("Cancel", role: .cancel) { pendingCategory = nil }
                    } message: {
                        Text("Apply to this transaction, or all \(matchCount) existing transactions and future transactions from \(entry.merchant). The merchant option replaces existing one-off category edits.")
                    }
            } else {
                ContentUnavailableView("Transaction unavailable", systemImage: "doc.questionmark")
            }
        }
    }
}

/// Hide only this list's native refresh spinner; the shared status shows sync progress.
private struct RefreshIndicatorHider: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe {
        let view = Probe()
        view.isUserInteractionEnabled = false
        return view
    }
    func updateUIView(_ view: Probe, context: Context) {
        view.hideIndicator()
        // SwiftUI can attach the refresh control after the row enters the hierarchy.
        DispatchQueue.main.async { view.hideIndicator() }
    }
    final class Probe: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            hideIndicator()
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            hideIndicator()
        }
        func hideIndicator() {
            var ancestor = superview
            while let view = ancestor {
                if let refreshControl = (view as? UIScrollView)?.refreshControl {
                    refreshControl.tintColor = .clear
                    return
                }
                ancestor = view.superview
            }
        }
    }
}

struct SourcesView: View {
    @EnvironmentObject private var store: BudgetStore
    @EnvironmentObject private var syncPresentation: AccountSyncPresentation
    @State private var openBankingReachedTop = false
    @State private var adding = false
    @State private var editingCredential: APICredentialService?
    @State private var selectedSource: BankProvider?
    @State private var selectedOfflineAccount: OfflineAccountSelection?
    private struct OfflineAccountSelection: Identifiable {
        let name: String
        var id: String { name }
    }
    var body: some View {
        NavigationStack {
            List {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accounts.")
                        .font(.system(size: 32, weight: .regular, design: .serif))
                        .foregroundStyle(ink).accessibilityAddTraits(.isHeader)
                }
                .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
                .background(RefreshIndicatorHider())

                Section {
                    if store.sources.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Image(systemName: "building.columns").font(.largeTitle).foregroundStyle(ink)
                            Text("Your money, in one place").font(.title3.weight(.semibold))
                            Text("Press the plus button in the top-right corner to add a bank or credit card.")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 16)
                    }
                    ForEach(store.sources) { bank in
                        Button { selectedSource = bank } label: {
                            HStack(spacing: 14) {
                                BankLogo(provider: bank, size: 44)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(bank.name).font(.subheadline.weight(.semibold)).foregroundStyle(ink)
                                    Text(store.bankStatus(bank.id)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }.padding(.vertical, 8)
                        }
                    }
                } header: {
                    Text("OPEN BANKING ACCOUNTS").font(.caption.weight(.semibold)).tracking(1.4)
                        .foregroundStyle(ink)
                        .background(SyncScrollObserver(onPull: { _ in }, onReachesTop: { reachedTop in
                            guard openBankingReachedTop != reachedTop else { return }
                            withAnimation(.easeInOut(duration: 0.2)) {
                                openBankingReachedTop = reachedTop
                            }
                        }))
                }
                  footer: { if !store.sources.isEmpty { Text("Select a bank to connect or sync its transactions.") } }
                Section {
                    let imported = store.visibleEntries.filter { $0.id.hasPrefix("csv:") || $0.id.hasPrefix("yonder:") }
                    ForEach(store.offlineAccounts, id: \.self) { account in
                        Button {
                            selectedOfflineAccount = OfflineAccountSelection(name: account)
                        } label: {
                            HStack(spacing: 14) {
                                BankLogo(provider: nil, fallback: account == "Yonder" ? "Y" : "C", size: 40)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(account).font(.subheadline.weight(.semibold)).foregroundStyle(ink)
                                    Text("\(imported.filter { $0.account == account }.count) imported transactions")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }.padding(.vertical, 5)
                        }
                    }
                } header: {
                    Text("OFFLINE ACCOUNTS").font(.caption.weight(.semibold)).tracking(1.4)
                        .foregroundStyle(ink)
                }
                if !store.isDemoSession {
                Section {
                    ForEach(APICredentialService.allCases) { service in
                        Button { editingCredential = service } label: {
                            HStack {
                                APICredentialLabel(service: service)
                                Spacer()
                                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("API CREDENTIALS").font(.caption.weight(.semibold)).tracking(1.4)
                        .foregroundStyle(ink)
                }
                }
            }.scrollContentBackground(.hidden).background(paper)
                .contentMargins(.horizontal, 22, for: .scrollContent)
                .contentMargins(.top, 0, for: .scrollContent)
                .navigationTitle("").navigationBarTitleDisplayMode(.inline)
                .refreshable { syncPresentation.start(store) }
                .accessibilityAction(named: Text("Sync accounts")) { syncPresentation.start(store) }
                .onAppear {
                    #if DEBUG
                    if ProcessInfo.processInfo.arguments.contains("--show-bank-picker") { adding = true }
                    #endif
                }
                .toolbar {
                    ToolbarItem(placement: .principal) {
                        AccountSyncStatus(presentation: syncPresentation, alwaysVisible: !openBankingReachedTop)
                            .frame(maxWidth: 260)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { adding = true } label: { Label("Add", systemImage: "plus") }
                            .disabled(store.isDemoSession)
                    }
                }
                .sheet(isPresented: $adding) { BankPickerView() }
                .sheet(item: $editingCredential) { APICredentialView(service: $0) }
                .sheet(item: $selectedSource) { bank in BankSourceView(provider: bank) }
                .sheet(item: $selectedOfflineAccount) { account in
                    NavigationStack {
                        Group {
                            if account.name == "Yonder" {
                                YonderAccountView()
                            } else {
                                TransactionsView(accountFilter: account.name)
                            }
                        }
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Done") { selectedOfflineAccount = nil }
                            }
                        }
                    }
                }
        }
    }

}

struct YonderAccountView: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var importing = false
    @State private var importPreview: CSVPreview?
    @State private var importMessage: String?
    @State private var completedImportMessage: String?

    var body: some View {
        TransactionsView(accountFilter: "Yonder")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Import") { importing = true }.disabled(store.isDemoSession)
                }
                if #available(iOS 26.0, *) {
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.commaSeparatedText], allowsMultipleSelection: false) { result in
                do {
                    if let url = try result.get().first { importPreview = try store.readImport(url) }
                } catch { importMessage = error.localizedDescription }
            }
            .sheet(item: $importPreview, onDismiss: {
                importMessage = completedImportMessage
                completedImportMessage = nil
            }) { preview in
                ImportReviewView(entries: preview.entries, onImportCompleted: {
                    completedImportMessage = store.message
                    store.message = nil
                })
            }
            .alert("Budget", isPresented: Binding(get: { importMessage != nil }, set: { if !$0 { importMessage = nil } })) {
                Button("OK") { importMessage = nil }
            } message: { Text(importMessage ?? "") }
    }
}


struct ImportReviewView: View {
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    let entries: [Entry]
    var onImportCompleted: (() -> Void)? = nil
    private var visibleEntries: [Entry] { entries.filter { $0.amount != 0 } }
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("\(visibleEntries.count) rows ready to review")
                    if visibleEntries.count != entries.count {
                        Text("Zero-value transactions are hidden.").font(.caption).foregroundStyle(.secondary)
                    }
                    Text("Money received is shown in green. Card repayments should be categorised as Transfer.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Previously imported rows are skipped automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(Array(visibleEntries.prefix(100).enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.description).lineLimit(2).truncationMode(.tail)
                                .foregroundStyle(entry.category == .transfer || entry.category == .income ? Color.secondary : ink)
                            Spacer()
                            TransactionAmount(entry: entry)
                        }
                        Text("\(entry.account) · \(entry.date.formatted(date: .abbreviated, time: .omitted)) · \(entry.category.rawValue)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if visibleEntries.count > 100 { Text("Showing the first 100 rows.").font(.caption) }
            }.navigationTitle("Review import").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Import") { dismiss(); store.commit(entries); onImportCompleted?() }
                            .disabled(entries.isEmpty)
                    }
                }
        }
    }
}
