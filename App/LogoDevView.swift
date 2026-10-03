import SwiftUI
import PhotosUI
import UniformTypeIdentifiers
import ImageIO

@MainActor
final class LogoDevService {
    private let isEnabled: Bool
    init(isEnabled: Bool = true) { self.isEnabled = isEnabled }
    var repository: BudgetRepository?
    private var inFlight: [String: Task<[Result], Error>] = [:]
    private let keychainService = "com.personal.budgetr.logo-dev"
    typealias Result = Retailer
    var hasKey: Bool { isEnabled && (try? BankKeychain.read("api-key", service: keychainService)) != nil }
    func savedKey() throws -> String {
        guard isEnabled else { return "" }
        guard let data = try BankKeychain.read("api-key", service: keychainService) else { return "" }
        guard let value = String(data: data, encoding: .utf8) else {
            throw CSVError.invalid("The saved Logo.dev key could not be read.")
        }
        return value
    }
    func saveKey(_ input: String) throws {
        guard isEnabled else { throw CSVError.invalid("API credentials are disabled in demo mode.") }
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
            guard key.hasPrefix("sk_"), !key.contains(where: { $0.isWhitespace }) else {
                throw CSVError.invalid("Use your Logo.dev secret key (sk_), not its publishable logo key.")
            }
            try BankKeychain.write(Data(key.utf8), account: "api-key", service: keychainService)
    }
    func lookup(description: String, newKey: String = "") async throws -> [Result] {
        guard isEnabled else { return [] }
        if !newKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try saveKey(newKey) }
        guard let repository else { throw CSVError.invalid("Retailer search storage is unavailable. Reopen saved data before searching.") }
        let query = description.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw CSVError.invalid("Enter a retailer name.") }
        if let cached = try repository.cachedRetailers(for: query) { return cached }
        guard let data = try BankKeychain.read("api-key", service: keychainService),
              let savedKey = String(data: data, encoding: .utf8) else {
            throw CSVError.invalid("Enter your Logo.dev secret API key.")
        }
        let cacheKey = Categorisation.merchantKey(query)
        if let task = inFlight[cacheKey] { return try await task.value }
        let task = Task { try await self.fetch(query: query, key: savedKey, repository: repository) }
        inFlight[cacheKey] = task
        defer { inFlight[cacheKey] = nil }
        return try await task.value
    }
    private func fetch(query: String, key: String, repository: BudgetRepository) async throws -> [Result] {
        var url = URLComponents(string: "https://api.logo.dev/search")!
        url.queryItems = [URLQueryItem(name: "q", value: query), URLQueryItem(name: "strategy", value: "match")]
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 30
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let session = URLSession(configuration: .ephemeral, delegate: BankSessionDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (body, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.statusCode == 200 else {
            switch http.statusCode {
            case 401: throw CSVError.invalid("Logo.dev rejected this API key. Check your secret key.")
            case 402, 403: throw CSVError.invalid("This key cannot use Brand Search. Check your key permissions and account allowance.")
            case 404: throw CSVError.invalid("Logo.dev returned HTTP 404 for Brand Search. This is an endpoint error, rather than an empty search result.")
            case 429: throw CSVError.invalid("Logo.dev's request limit was reached. Try again later.")
            default: throw CSVError.invalid("Logo.dev lookup failed (HTTP \(http.statusCode)).")
            }
        }
        let result = try JSONDecoder().decode([Result].self, from: body)
        try repository.cacheRetailers(result, for: query)
        return result
    }
}

enum APICredentialService: String, Identifiable, CaseIterable {
    case logoDev, trueLayer
    var id: String { rawValue }
    var title: String { self == .logoDev ? "Logo.dev" : "TrueLayer" }
    var iconName: String { self == .logoDev ? "LogoDev" : "TrueLayer" }
    var fieldTitle: String { self == .logoDev ? "Secret API key (sk_)" : "Client secret" }
    var explanation: String {
        self == .logoDev
            ? "Used for retailer names and logos. Your secret key is stored securely in this iPhone’s Keychain."
            : "Shared by all your bank connections. Your client secret is stored securely in this iPhone’s Keychain."
    }
}

struct APICredentialLabel: View {
    let service: APICredentialService
    var body: some View {
        HStack(spacing: 14) {
            Image(service.iconName).resizable().scaledToFit()
                .padding(service == .logoDev ? 0 : 7).frame(width: 40, height: 40)
                .background(.white, in: RoundedRectangle(cornerRadius: 10))
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .accessibilityHidden(true)
            Text(service.title).font(.subheadline.weight(.semibold))
        }.padding(.vertical, 5)
    }
}

struct APICredentialView: View {
    let service: APICredentialService
    @EnvironmentObject private var store: BudgetStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var secret = ""
    @State private var revealed = false
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Group {
                            if revealed {
                                TextField(service.fieldTitle, text: $secret)
                            } else {
                                SecureField(service.fieldTitle, text: $secret)
                            }
                        }
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .privacySensitive()
                        Button { revealed.toggle() } label: {
                            Image(systemName: revealed ? "eye.slash" : "eye")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(revealed ? "Hide credential" : "Show credential")
                        .disabled(secret.isEmpty)
                    }
                } header: {
                    APICredentialLabel(service: service).textCase(nil)
                } footer: {
                    Text(service.explanation)
                }
                if let error { Section { Text(error).foregroundStyle(.secondary) } }
            }
            .scrollContentBackground(.hidden)
            .background(Color(red: 0.96, green: 0.95, blue: 0.92))
            .navigationTitle(service.title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            switch service {
                            case .logoDev:
                                try store.logoService.saveKey(secret)
                                Task { await store.recogniseMerchants() }
                            case .trueLayer:
                                try store.bankService.saveClientSecret(secret)
                            }
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(!loaded || secret.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                do {
                    secret = try service == .logoDev ? store.logoService.savedKey() : store.bankService.savedClientSecret()
                    loaded = true
                } catch { self.error = error.localizedDescription }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { revealed = false }
            }
            .onDisappear { secret = ""; revealed = false; loaded = false }
        }
    }
}

struct RetailerArtwork: View {
    @EnvironmentObject private var store: BudgetStore
    @State private var artwork: UIImage?
    @State private var loadedSource: ArtworkSource?
    private struct ArtworkSource: Hashable {
        let url: URL?
        let customData: Data?
    }
    private var source: ArtworkSource {
        ArtworkSource(url: retailer?.logoURL, customData: retailer?.customIconData)
    }
    let retailer: Retailer?
    let fallback: String
    var size: CGFloat = 42
    var fallbackColor: Color = Color(red: 0.12, green: 0.22, blue: 0.19)
    private var fallbackImage: some View {
        Image(systemName: fallback).symbolVariant(.none).foregroundStyle(fallbackColor)
    }
    var body: some View {
        Group {
            if loadedSource == source, let artwork {
                Image(uiImage: artwork).resizable().scaledToFill()
            } else { fallbackImage }
        }
        .frame(width: size, height: size)
        .background(.white, in: RoundedRectangle(cornerRadius: size / 3))
        .clipShape(RoundedRectangle(cornerRadius: size / 3))
        .task(id: source) {
            artwork = nil
            loadedSource = nil
            let requested = source
            let data: Data
            if let customData = requested.customData {
                data = customData
            } else if let url = requested.url, let downloaded = try? await store.logoCache.data(for: url) {
                data = downloaded
            } else { return }
            guard !Task.isCancelled else { return }
            artwork = UIImage(data: data)
            loadedSource = requested
        }
    }
}

struct CustomRetailerView: View {
    let entry: Entry
    let onSave: () -> Void
    @EnvironmentObject private var store: BudgetStore
    @State private var name: String
    @State private var draft: Retailer
    @State private var draftsByName: [String: Retailer] = [:]
    @FocusState private var nameFocused: Bool
    @State private var selectedSuggestionName: String?
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var importingImage = false
    @State private var loadingImage = false
    @State private var error: String?
    @State private var iconCandidates: [Retailer] = []
    @State private var searchingIcons = false
    @State private var iconSearchError: String?
    @State private var iconSearchRequest = UUID()
    @State private var editingLogoSettings = false
    @State private var matchingPattern: String
    @State private var matchDescription: Bool
    @State private var matchingEntries: [Entry] = []
    @State private var patternError: String?
    @State private var checkingPattern = false
    let ruleOwner: String?

    init(entry: Entry, retailer: Retailer?, displayName: String, matchingPattern: String = "", matchDescription: Bool = false, ruleOwner: String? = nil, onSave: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        self.ruleOwner = ruleOwner
        _matchingPattern = State(initialValue: matchingPattern)
        _matchDescription = State(initialValue: matchDescription)
        _name = State(initialValue: displayName)
        _draft = State(initialValue: retailer ?? Retailer(name: displayName, domain: nil, logo_url: nil))
    }

    private func heading(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).tracking(1.4)
            .foregroundStyle(Color(red: 0.12, green: 0.22, blue: 0.19))
    }

    private var effectiveName: String {
        MerchantIconSharing.resolvedName(name, original: entry.merchant)
    }

    private var nameSuggestions: [Retailer] {
        store.merchantSuggestions(for: effectiveName)
    }

    private func matchesDraft(_ retailer: Retailer) -> Bool {
        let suggestedName = retailer.name ?? retailer.domain ?? effectiveName
        guard MerchantSummary.normalisedName(suggestedName) == MerchantSummary.normalisedName(effectiveName) else {
            return false
        }
        if draft.customIconData != nil || retailer.customIconData != nil {
            return draft.customIconData == retailer.customIconData
        }
        return draft.logoURL == retailer.logoURL
    }

    private var selectedLocalSuggestion: Int? {
        nameSuggestions.firstIndex(where: matchesDraft)
    }

    private var selectedRemoteSuggestion: Int? {
        guard selectedLocalSuggestion == nil else { return nil }
        return iconCandidates.firstIndex { $0.logoURL != nil && matchesDraft($0) }
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 12) {
                    RetailerArtwork(retailer: draft, fallback: entry.category.symbol, size: 72, fallbackColor: entry.category.color)
                    Text(effectiveName)
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                }.frame(maxWidth: .infinity).padding(.vertical, 12)
            }.listRowBackground(Color.clear)
            Section {
                HStack(spacing: 12) {
                    TextField(entry.merchant, text: $name)
                        .textInputAutocapitalization(.words).autocorrectionDisabled()
                        .focused($nameFocused)
                    Button { name = ""; nameFocused = true } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityLabel("Clear merchant name")
                }
            } header: { heading("NAME") }
            if nameFocused {
                if !nameSuggestions.isEmpty {
                    Section {
                        ForEach(Array(nameSuggestions.enumerated()), id: \.offset) { index, retailer in
                            Button {
                                selectSuggestion(retailer)
                            } label: {
                                HStack(spacing: 12) {
                                    RetailerArtwork(retailer: retailer, fallback: entry.category.symbol, size: 32, fallbackColor: entry.category.color)
                                    Text(retailer.name ?? "").foregroundStyle(.primary).lineLimit(2)
                                    Spacer()
                                    if selectedLocalSuggestion == index {
                                        Image(systemName: "checkmark")
                                    }
                                }.contentShape(Rectangle())
                            }.disabled(loadingImage)
                        }
                    } header: { heading("SUGGESTIONS") }
                }
                Section {
                    if searchingIcons { ProgressView("Searching for icons…") }
                    if !store.logoService.hasKey && !store.isDemoSession {
                        Button("Set up Logo.dev") { editingLogoSettings = true }
                    }
                    if let iconSearchError {
                        Text(iconSearchError).font(.subheadline).foregroundStyle(.secondary)
                    }
                    ForEach(Array(iconCandidates.enumerated()), id: \.offset) { index, retailer in
                        Button { selectSuggestion(retailer) } label: {
                            HStack(spacing: 12) {
                                RetailerArtwork(retailer: retailer, fallback: "building.2", size: 32)
                                Text(retailer.name ?? "Icon")
                                    .foregroundStyle(.primary).lineLimit(2)
                                Spacer()
                                if selectedRemoteSuggestion == index {
                                    Image(systemName: "checkmark")
                                }
                            }.contentShape(Rectangle())
                        }.disabled(loadingImage || retailer.logoURL == nil)
                    }
                } header: { heading("LOGO.DEV SUGGESTIONS") }
            }
            Section {
                Toggle("Match transaction description", isOn: $matchDescription)
                TextField("e.g. ^NETFLIX\\b", text: $matchingPattern, axis: .vertical)
                    .font(.body.monospaced())
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("Merchant matching regular expression")
                if let patternError {
                    Text(patternError).font(.caption).foregroundStyle(.red)
                }
            } header: { heading("MATCHING RULE") } footer: {
                Text("Case-insensitive regex matched against the original \(matchDescription ? "transaction description" : "merchant name"), across all accounts. Applies this name and icon to existing and future matches. The most recently saved matching rule wins. Clear to remove the rule.")
            }
            if !matchingPattern.isEmpty {
                Section {
                    if checkingPattern { ProgressView("Finding matches…") }
                    else if matchingEntries.isEmpty && patternError == nil { Text("No matching transactions").foregroundStyle(.secondary) }
                    ForEach(matchingEntries) { transaction in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(transaction.description).font(.subheadline).lineLimit(2)
                            HStack {
                                Text(transaction.date, format: .dateTime.day().month().year())
                                Text(transaction.account).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(transaction.amount, format: .currency(code: transaction.currency))
                            }.font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: { heading("MATCHED TRANSACTIONS (\(matchingEntries.count))") }
            }
            Section {
                PhotosPicker(selection: $selectedPhoto, matching: .images) {
                    Label("Choose from Photos", systemImage: "photo")
                }.disabled(loadingImage)
                Button { importingImage = true } label: {
                    Label("Choose image from Files", systemImage: "folder")
                }.disabled(loadingImage)
                if draft.customIconData != nil || draft.logoURL != nil {
                    Button("Remove icon", role: .destructive) {
                        draft.customIconData = nil
                        draft.logo_url = nil
                        selectedPhoto = nil
                    }.disabled(loadingImage)
                }
                if loadingImage { ProgressView("Preparing image…") }
            } header: { heading("ICON") } footer: {
                Text("Optional. Without an icon, the transaction’s category icon is used.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Color(red: 0.96, green: 0.95, blue: 0.92))
        .navigationTitle("Edit Merchant").navigationBarTitleDisplayMode(.inline)
        .onChange(of: name) { oldName, newName in
            if selectedSuggestionName == newName {
                selectedSuggestionName = nil
                return
            }
            let oldKey = MerchantSummary.normalisedName(MerchantIconSharing.resolvedName(oldName, original: entry.merchant))
            let resolved = MerchantIconSharing.resolvedName(newName, original: entry.merchant)
            let newKey = MerchantSummary.normalisedName(resolved)
            guard oldKey != newKey else { return }
            draftsByName[oldKey] = draft
            if let icon = draftsByName[newKey] ?? store.existingMerchantIcon(named: resolved) {
                draft = MerchantIconSharing.applyingIcon(icon, to: draft)
                selectedPhoto = nil
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    draft.name = effectiveName
                    if store.saveCustomRetailer(draft, for: entry, matchingPattern: matchingPattern, matchDescription: matchDescription, ruleOwner: ruleOwner) { onSave() }
                    else {
                        error = store.message ?? "Your merchant details could not be saved. Please try again."
                        store.message = nil
                    }
                }.disabled(loadingImage || checkingPattern || patternError != nil)
            }
        }
        .task(id: "\(matchDescription)|\(matchingPattern)") {
            matchingEntries = []
            patternError = nil
            guard !matchingPattern.isEmpty else { checkingPattern = false; return }
            checkingPattern = true
            let pattern = matchingPattern
            let useDescription = matchDescription
            let entries = store.entries
            do {
                try await Task.sleep(for: .milliseconds(300))
                let result = await Task.detached(priority: .userInitiated) { () -> Result<[Entry], Error> in
                    do {
                        var match = MerchantMatch(retailer: nil)
                        match.matchingPattern = pattern
                        match.matchDescription = useDescription
                        let rule = try MerchantMatchingRule(owner: "preview", match: match)
                        return .success(entries.filter { rule.matches($0) }.sorted { $0.date > $1.date })
                    } catch { return .failure(error) }
                }.value
                try Task.checkCancellation()
                switch result {
                case .success(let entries): matchingEntries = entries
                case .failure(let error): patternError = error.localizedDescription
                }
                checkingPattern = false
            } catch { }
        }
        .task(id: "\(nameFocused)|\(effectiveName)|\(iconSearchRequest)") {
            let query = effectiveName
            iconCandidates = []
            iconSearchError = nil
            searchingIcons = false
            guard nameFocused, !query.isEmpty, store.logoService.hasKey else { return }
            do {
                // Restart the delay on every edit, and never display stale results.
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                searchingIcons = true
                let candidates = try await store.logoService.lookup(description: query)
                try Task.checkCancellation()
                guard query == effectiveName else { return }
                iconCandidates = candidates
                if candidates.isEmpty {
                    iconSearchError = "No icons found. Try another name or choose an image from Photos or Files."
                }
            } catch {
                guard !Task.isCancelled else { return }
                iconSearchError = error.localizedDescription
            }
            if !Task.isCancelled { searchingIcons = false }
        }
        .sheet(isPresented: $editingLogoSettings, onDismiss: { iconSearchRequest = UUID() }) {
            APICredentialView(service: .logoDev)
        }
        .task(id: selectedPhoto) {
            guard let selectedPhoto else { return }
            loadingImage = true
            defer { loadingImage = false }
            do {
                guard let data = try await selectedPhoto.loadTransferable(type: Data.self) else {
                    throw CSVError.invalid("This photo could not be opened. Choose another image.")
                }
                try await setIcon(data)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
        .fileImporter(isPresented: $importingImage, allowedContentTypes: [.image]) { result in
            Task {
                loadingImage = true
                defer { loadingImage = false }
                do {
                    let url = try result.get()
                    let granted = url.startAccessingSecurityScopedResource()
                    defer { if granted { url.stopAccessingSecurityScopedResource() } }
                    let data = try await Task.detached(priority: .userInitiated) {
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= MerchantIconImage.maximumInputSize else {
                            throw CSVError.invalid("Choose an image smaller than 20 MB.")
                        }
                        return try Data(contentsOf: url)
                    }.value
                    try await setIcon(data)
                } catch {
                    if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription }
                }
            }
        }
        .alert("Couldn’t update merchant", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }

    private func selectSuggestion(_ retailer: Retailer) {
        draftsByName[MerchantSummary.normalisedName(effectiveName)] = draft
        let selectedName = retailer.name ?? retailer.domain ?? effectiveName
        draftsByName[MerchantSummary.normalisedName(selectedName)] = retailer
        if name != selectedName { selectedSuggestionName = selectedName }
        name = selectedName
        draft = MerchantIconSharing.applyingIcon(retailer, to: draft)
        selectedPhoto = nil
        nameFocused = false
    }

    private func setIcon(_ data: Data) async throws {
        let icon = try await Task.detached(priority: .userInitiated) {
            try MerchantIconImage.prepare(data)
        }.value
        try Task.checkCancellation()
        draft.customIconData = icon
        draft.logo_url = nil
    }
}
