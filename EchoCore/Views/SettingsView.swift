import SwiftUI
import StoreKit
import UniformTypeIdentifiers

struct SettingsView: View {
    @Environment(PlayerModel.self) private var model
    @Environment(SettingsManager.self) private var settings
    @Environment(StoreManager.self) private var storeManager
    @Environment(\.dismiss) private var dismiss
    @State private var isPurchasingPro = false
    @State private var isRestoringPurchases = false
    @State private var isRetryingProducts = false
    @State private var showingDeckImporter = false
    @State private var importAlert: (title: String, message: String)?
    @State private var volumeBoostEnabled = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Display") {
                    NavigationLink("Appearance") {
                        SettingsAppearanceView()
                    }
                }

                Section("Store") {
                    NavigationLink("Pro Transcripts") {
                        ProTranscriptsSettingsView(
                            isPurchasingPro: $isPurchasingPro,
                            isRestoringPurchases: $isRestoringPurchases,
                            isRetryingProducts: $isRetryingProducts
                        )
                    }
                }

                Section("Customization") {
                    NavigationLink("Phone Player Designer") {
                        PhonePlayerSettingsView()
                    }
                    NavigationLink("Watch App Settings") {
                        WatchAppSettingsView()
                    }
                }

                Section("Playback") {
                    Toggle("Volume Boost", isOn: $volumeBoostEnabled)
                        .onAppear { volumeBoostEnabled = model.isVolumeBoostEnabled }
                        .onChange(of: volumeBoostEnabled) { _, newValue in
                            model.setVolumeBoost(enabled: newValue)
                        }
                        .onChange(of: model.isVolumeBoostEnabled) { _, newValue in
                            volumeBoostEnabled = newValue
                        }
                    Picker("Default Speed", selection: $settings.defaultPlaybackSpeed) {
                        Text("1.0×").tag(1.0)
                        Text("1.25×").tag(1.25)
                        Text("1.5×").tag(1.5)
                        Text("2.0×").tag(2.0)
                        Text("3.0×").tag(3.0)
                    }
                    Picker("Seek Backward", selection: Binding(
                        get: { settings.seekBackwardDuration },
                        set: {
                            settings.seekBackwardDuration = $0
                            model.syncToWatch()
                        }
                    )) {
                        ForEach([5, 10, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300], id: \.self) { duration in
                            Text("\(duration)s").tag(duration)
                        }
                    }
                    Picker("Seek Forward", selection: Binding(
                        get: { settings.seekForwardDuration },
                        set: {
                            settings.seekForwardDuration = $0
                            model.syncToWatch()
                        }
                    )) {
                        ForEach([5, 10, 15, 30, 45, 60, 75, 90, 120, 150, 180, 240, 300], id: \.self) { duration in
                            Text("\(duration)s").tag(duration)
                        }
                    }
                    NavigationLink("Smart Rewind") {
                        SmartRewindSettingsView()
                    }
                }

                SettingsSilenceDetectionSection()

                SettingsAutoAlignmentSection()

                SettingsBookmarksInlineSection()

                Section("Flashcards") {
                    Button {
                        showingDeckImporter = true
                    } label: {
                        Label("Import Deck", systemImage: "square.and.arrow.down")
                    }
                }

                #if DEBUG
                Section {
                    Button("Load Development Assets") {
                        model.loadFolder(Bundle.main.bundleURL)
                        dismiss()
                    }
                } header: {
                    Text("Debug Menu")
                } footer: {
                    Text("Loads audio files from Development Assets into the player.")
                }
                #endif

                Section {
                    NavigationLink("Help") {
                        HelpView()
                            .navigationTitle("Help")
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .environment(\.font, settings.appFont == SettingsManager.systemFontName ? .body : .custom(settings.appFont, size: 17, relativeTo: .body))
        .fileImporter(
            isPresented: $showingDeckImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        .alert(importAlert?.title ?? "", isPresented: isShowingAlert) {
            Button("OK") { importAlert = nil }
        } message: {
            if let message = importAlert?.message {
                Text(message)
            }
        }
        .preferredColorScheme(settings.isDarkMode ? .dark : .light)
        .tint(ThemeColor(rawValue: settings.themeColor)?.color)
    }

    // MARK: - Helpers

    private var isShowingAlert: Binding<Bool> {
        Binding(
            get: { importAlert != nil },
            set: { if !$0 { importAlert = nil } }
        )
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first, let db = model.databaseService else { return }
            let importer = DeckImportService()
            do {
                let count = try importer.importDeck(from: url, db: db.writer)
                importAlert = ("Import Complete", "Imported \(count) cards successfully.")
            } catch {
                importAlert = ("Import Failed", error.localizedDescription)
            }
        case .failure(let error):
            importAlert = ("Import Failed", error.localizedDescription)
        }
    }
}

// MARK: - Extracted Section Views

private struct SettingsAppearanceView: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Form {
            Section {
                Toggle("Dark Mode", isOn: $settings.isDarkMode)
                    .tint(ThemeColor(rawValue: settings.themeColor)?.color)
            }
            Section("Theme") {
                NavigationLink {
                    ThemeSelectionView()
                } label: {
                    HStack {
                        Text("Accent Color")
                        Spacer()
                        if let color = ThemeColor(rawValue: settings.themeColor)?.color {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(color)
                        } else {
                            Text("System")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            Section("Typography") {
                NavigationLink {
                    FontSelectionView()
                } label: {
                    HStack {
                        Text("Font")
                        Spacer()
                        Text(settings.appFont == SettingsManager.systemFontName ? "System" : settings.appFont)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .navigationTitle("Appearance")
        .tint(ThemeColor(rawValue: settings.themeColor)?.color)
        .accentColor(ThemeColor(rawValue: settings.themeColor)?.color)
    }
}

private struct FontSelectionView: View {
    @Environment(SettingsManager.self) private var settings
    
    var body: some View {
        Form {
            Button { settings.appFont = "Lexend" } label: {
                HStack {
                    Text("Lexend (Default)")
                        .foregroundStyle(.primary)
                    Spacer()
                    if settings.appFont == "Lexend" {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            Button { settings.appFont = "OpenDyslexic" } label: {
                HStack {
                    Text("OpenDyslexic")
                        .foregroundStyle(.primary)
                    Spacer()
                    if settings.appFont == "OpenDyslexic" {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            Button { settings.appFont = SettingsManager.systemFontName } label: {
                HStack {
                    Text("System")
                        .foregroundStyle(.primary)
                    Spacer()
                    if settings.appFont == SettingsManager.systemFontName {
                        Image(systemName: "checkmark")
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
        }
        .navigationTitle("Font")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SettingsSilenceDetectionSection: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Lookback Duration")
                    Spacer()
                    Text(String(format: "%.1fs", settings.silenceDetectionLookbackSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $settings.silenceDetectionLookbackSeconds, in: 1...30, step: 0.5)
            }
        } header: {
            Text("Silence Detection")
        } footer: {
            Text("How far back to scan for silence when locating playback position during reverse playback. For testing.")
        }
    }
}

private struct SettingsAutoAlignmentSection: View {
    @Environment(SettingsManager.self) private var settings
    @Environment(PlayerModel.self) private var model

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Continuous Auto-Alignment", isOn: Binding(
                get: { settings.continuousAutoAlignmentEnabled },
                set: {
                    settings.continuousAutoAlignmentEnabled = $0
                    model.configureContinuousAlignment()
                }
            ))
        } header: {
            Text("Auto-Alignment")
        } footer: {
            Text("When enabled, the app will continuously transcribe audio in the background while playing and attempt to align it with the text.")
        }
    }
}

private struct SettingsBookmarksInlineSection: View {
    @Environment(SettingsManager.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Toggle("Play Bookmarks Inline", isOn: $settings.playBookmarksInline)
        } footer: {
            Text("When enabled, voice memos attached to bookmarks are played automatically when the audiobook reaches that timestamp.")
        }
    }
}

// MARK: - ProTranscriptsSettingsView

private struct ProTranscriptsSettingsView: View {
    @Environment(StoreManager.self) private var storeManager
    @Binding var isPurchasingPro: Bool
    @Binding var isRestoringPurchases: Bool
    @Binding var isRetryingProducts: Bool

    var body: some View {
        Form {
            Section {
                LabeledContent("Status") {
                    Text(storeManager.hasUnlockedPro ? String(localized: "Unlocked") : String(localized: "Locked"))
                        .foregroundStyle(storeManager.hasUnlockedPro ? .green : .secondary)
                }

                if let product = storeManager.proUnlockProduct, !storeManager.hasUnlockedPro {
                    Button {
                        Task { await purchasePro() }
                    } label: {
                        if isPurchasingPro {
                            ProgressView()
                        } else {
                            Text(String(localized: "Unlock for \(product.displayPrice)"))
                        }
                    }
                    .disabled(isPurchasingPro || isRestoringPurchases)
                } else if !storeManager.hasUnlockedPro {
                    Button {
                        Task { await retryProducts() }
                    } label: {
                        if isRetryingProducts {
                            ProgressView()
                        } else {
                            Text("Retry Loading Purchase")
                        }
                    }
                    .disabled(isRetryingProducts || isPurchasingPro || isRestoringPurchases)
                }

                Button {
                    Task { await restorePurchases() }
                } label: {
                    if isRestoringPurchases {
                        ProgressView()
                    } else {
                        Text("Restore Purchases")
                    }
                }
                .disabled(isPurchasingPro || isRestoringPurchases)
            } footer: {
                Text("Unlock transcript overlays for audiobooks with transcript sidecars.")
            }

            if let lastStoreError = storeManager.lastStoreError {
                Section {
                    Text(lastStoreError)
                        .foregroundStyle(.red)
                } header: {
                    Text("StoreKit Error")
                }
            }
        }
        .navigationTitle("Pro Transcripts")
        .task {
            if storeManager.proUnlockProduct == nil {
                await storeManager.requestProducts()
            }
        }
    }

    private func purchasePro() async {
        isPurchasingPro = true
        defer { isPurchasingPro = false }
        do {
            try await storeManager.purchaseProUnlock()
        } catch {
            storeManager.recordStoreError(error)
        }
    }

    private func restorePurchases() async {
        isRestoringPurchases = true
        defer { isRestoringPurchases = false }
        await storeManager.restorePurchases()
    }

    private func retryProducts() async {
        isRetryingProducts = true
        defer { isRetryingProducts = false }
        await storeManager.requestProducts()
    }
}

private struct ThemeSelectionView: View {
    @Environment(SettingsManager.self) private var settings
    
    var body: some View {
        Form {
            ForEach(ThemeColor.allCases) { theme in
                Button {
                    settings.themeColor = theme.rawValue
                } label: {
                    HStack {
                        if theme != .system {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(theme.color ?? Color.accentColor)
                        } else {
                            Image(systemName: "circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        
                        Text(theme.rawValue)
                            .foregroundStyle(.primary)
                        
                        Spacer()
                        
                        if settings.themeColor == theme.rawValue {
                            Image(systemName: "checkmark")
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        }
        .navigationTitle("Accent Color")
        .navigationBarTitleDisplayMode(.inline)
    }
}

enum ThemeColor: String, CaseIterable, Identifiable {
    case system = "System"
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case mint = "Mint"
    case teal = "Teal"
    case cyan = "Cyan"
    case indigo = "Indigo"
    
    var id: String { self.rawValue }
    
    var color: Color? {
        switch self {
        case .system: return nil
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .mint: return .mint
        case .teal: return .teal
        case .cyan: return .cyan
        case .indigo: return .indigo
        }
    }
}
