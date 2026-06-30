// SPDX-License-Identifier: GPL-3.0-or-later
import Observation
import SwiftUI
import os.log

/// macOS Audiobookshelf orchestration over the shared, macOS-clean ABS services
/// (AudiobookshelfService / ABSTokenStore / ABSImportService / ABSServerDAO).
/// The iOS `PlayerModel+Audiobookshelf` and ABS views are not part of the macOS
/// target, so macOS drives the services directly. v1 supports one connected
/// server (matching iOS). Two-way progress sync is a follow-up.
@MainActor
@Observable
final class MacAudiobookshelfViewModel {
    enum Phase { case disconnected, connecting, connected }

    var phase: Phase = .disconnected
    var server: ABSServerRecord?
    var errorMessage: String?

    // Connect form
    var serverURLText: String = ""
    var username: String = ""
    var password: String = ""

    // Pending user confirmations
    var pendingPlainHTTP: Bool = false
    var pendingCert: PendingCert?

    struct PendingCert: Identifiable {
        let id = UUID()
        let host: String
        let sha256: String
    }

    // Browse
    var libraries: [ABSLibrary] = []
    var selectedLibraryID: String?
    var items: [ABSLibraryItem] = []
    var searchQuery: String = ""
    var isLoading: Bool = false
    var importingItemID: String?

    @ObservationIgnored private let db: DatabaseService
    @ObservationIgnored private var service: AudiobookshelfService?
    @ObservationIgnored private var serverID: String?
    @ObservationIgnored private let onPlay: (URL) -> Void
    @ObservationIgnored private let logger = Logger(
        subsystem: "com.echo.audiobooks", category: "MacABS")

    init(db: DatabaseService, onPlay: @escaping (URL) -> Void) {
        self.db = db
        self.onPlay = onPlay
    }

    // MARK: Lifecycle

    func load() async {
        guard let record = try? ABSServerDAO(db: db.writer).current() else {
            phase = .disconnected
            return
        }
        server = record
        serverID = record.id
        service = makeService(for: record)
        phase = .connected
        await loadLibraries()
    }

    private func makeService(for record: ABSServerRecord) -> AudiobookshelfService? {
        guard let baseURL = URL(string: record.baseURL) else { return nil }
        let tokens = ABSTokenStore(serverID: record.id)
        let host = baseURL.host?.lowercased() ?? ""
        let (session, delegate) = ABSURLSession.make(
            expectedHost: host, pinnedSHA256: tokens.pinnedCertificateSHA256)
        return AudiobookshelfService(
            baseURL: baseURL, tokens: tokens, session: session, trustDelegate: delegate)
    }

    // MARK: Connect

    func connect() async {
        errorMessage = nil
        guard let baseURL = ABSEndpoints.normalizedBaseURL(from: serverURLText) else {
            errorMessage = "Enter a valid server URL."
            return
        }
        if ABSEndpoints.requiresPlainHTTPConfirmation(baseURL) {
            pendingPlainHTTP = true
            return
        }
        await attemptConnect(baseURL: baseURL, trustingCertificate: nil)
    }

    func confirmPlainHTTP() async {
        pendingPlainHTTP = false
        guard let baseURL = ABSEndpoints.normalizedBaseURL(from: serverURLText) else { return }
        await attemptConnect(baseURL: baseURL, trustingCertificate: nil)
    }

    func trustCertificateAndConnect() async {
        guard let cert = pendingCert,
            let baseURL = ABSEndpoints.normalizedBaseURL(from: serverURLText)
        else { return }
        pendingCert = nil
        await attemptConnect(baseURL: baseURL, trustingCertificate: cert.sha256)
    }

    private func attemptConnect(baseURL: URL, trustingCertificate: String?) async {
        phase = .connecting
        errorMessage = nil
        let newServerID = serverID ?? UUID().uuidString
        let tokens = ABSTokenStore(serverID: newServerID)
        if let cert = trustingCertificate { tokens.pinnedCertificateSHA256 = cert }
        let host = baseURL.host?.lowercased() ?? ""
        let (session, delegate) = ABSURLSession.make(
            expectedHost: host, pinnedSHA256: tokens.pinnedCertificateSHA256)
        let svc = AudiobookshelfService(
            baseURL: baseURL, tokens: tokens, session: session, trustDelegate: delegate)
        do {
            let defaultLib = try await svc.login(username: username, password: password)
            let record = ABSServerRecord(
                id: newServerID,
                baseURL: baseURL.absoluteString,
                username: username,
                defaultLibraryId: defaultLib,
                addedAt: Date().ISO8601Format())
            try ABSServerDAO(db: db.writer).save(record)
            service = svc
            serverID = newServerID
            server = record
            password = ""
            phase = .connected
            await loadLibraries()
        } catch let absError as ABSError {
            svc.invalidate()
            phase = .disconnected
            if case .untrustedCertificate(let h, let sha) = absError {
                pendingCert = PendingCert(host: h, sha256: sha)
            } else {
                errorMessage = absError.errorDescription ?? "Could not connect to the server."
            }
        } catch {
            svc.invalidate()
            phase = .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        if let svc = service {
            _ = await svc.signOut()
            svc.invalidate()
        }
        if let sid = serverID { ABSTokenStore(serverID: sid).clear() }
        if let record = server { try? ABSServerDAO(db: db.writer).delete(record.id) }
        service = nil
        serverID = nil
        server = nil
        libraries = []
        items = []
        selectedLibraryID = nil
        phase = .disconnected
    }

    // MARK: Browse

    func loadLibraries() async {
        guard let service else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            libraries = try await service.libraries()
            if selectedLibraryID == nil {
                selectedLibraryID = server?.defaultLibraryId ?? libraries.first?.id
            }
            await loadItems()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func loadItems() async {
        guard let service, let libraryID = selectedLibraryID else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.allItems(libraryID: libraryID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func runSearch() async {
        guard let service, let libraryID = selectedLibraryID else { return }
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            await loadItems()
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await service.search(libraryID: libraryID, query: query)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Downloads + imports the item into the local library and hands the folder to
    /// the player for playback. Returns true on success (caller dismisses).
    func addToLibrary(_ item: ABSLibraryItem) async -> Bool {
        guard let service, let sid = serverID else { return false }
        importingItemID = item.id
        defer { importingItemID = nil }
        do {
            let importer = ABSImportService(service: service, db: db, serverID: sid)
            let folderURL = try await importer.prepareLocalFolder(for: item)
            onPlay(folderURL)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}

/// macOS Audiobookshelf connect + browse + download sheet. Reached via
/// File ▸ Connect to Audiobookshelf….
struct MacAudiobookshelfView: View {
    @State private var model: MacAudiobookshelfViewModel
    @Environment(\.dismiss) private var dismiss

    init(db: DatabaseService, onPlay: @escaping (URL) -> Void) {
        _model = State(initialValue: MacAudiobookshelfViewModel(db: db, onPlay: onPlay))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            switch model.phase {
            case .disconnected: connectForm
            case .connecting:
                ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected: browse
            }
        }
        .frame(width: 580, height: 500)
        .padding()
        .task { await model.load() }
        .alert(
            "Use an unencrypted connection?",
            isPresented: Binding(
                get: { model.pendingPlainHTTP },
                set: { if !$0 { model.pendingPlainHTTP = false } })
        ) {
            Button("Cancel", role: .cancel) { model.pendingPlainHTTP = false }
            Button("Connect Anyway") { Task { await model.confirmPlainHTTP() } }
        } message: {
            Text(
                "This server uses plain HTTP. Your username and password will be sent unencrypted.")
        }
        .alert(item: $model.pendingCert) { cert in
            Alert(
                title: Text("Trust this server's certificate?"),
                message: Text(
                    "The server presented a self-signed certificate.\nSHA-256: "
                        + ABSCertificateFingerprint.display(cert.sha256)),
                primaryButton: .default(Text("Trust")) {
                    Task { await model.trustCertificateAndConnect() }
                },
                secondaryButton: .cancel())
        }
    }

    private var header: some View {
        HStack {
            Text("Audiobookshelf").font(.headline)
            Spacer()
            if model.phase == .connected, let server = model.server {
                Text(server.username).foregroundStyle(.secondary)
                Button("Sign Out") { Task { await model.disconnect() } }
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
    }

    private var connectForm: some View {
        Form {
            Section {
                TextField(
                    "Server URL", text: $model.serverURLText, prompt: Text("https://host:13378")
                )
                .textContentType(.URL)
                TextField("Username", text: $model.username)
                SecureField("Password", text: $model.password)
            } footer: {
                if let error = model.errorMessage {
                    Text(error).foregroundStyle(.red).font(.callout)
                }
            }
            Button("Connect") { Task { await model.connect() } }
                .buttonStyle(.borderedProminent)
                .disabled(model.serverURLText.isEmpty || model.username.isEmpty)
        }
        .formStyle(.grouped)
    }

    private var browse: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("Library", selection: $model.selectedLibraryID) {
                    ForEach(model.libraries) { library in
                        Text(library.name).tag(Optional(library.id))
                    }
                }
                .labelsHidden()
                .onChange(of: model.selectedLibraryID) { _, _ in Task { await model.loadItems() } }

                TextField("Search", text: $model.searchQuery)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await model.runSearch() } }
            }

            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).font(.caption)
            }

            if model.isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if model.items.isEmpty {
                ContentUnavailableView(
                    "No items", systemImage: "books.vertical",
                    description: Text(
                        "This library has no audiobooks, or the search found nothing."))
            } else {
                List(model.items) { item in
                    itemRow(item)
                }
            }
        }
    }

    private func itemRow(_ item: ABSLibraryItem) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title ?? "Untitled").fontWeight(.medium)
                if let author = item.author {
                    Text(author).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.importingItemID == item.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Add") {
                    Task {
                        if await model.addToLibrary(item) { dismiss() }
                    }
                }
                .controlSize(.small)
                .disabled(model.importingItemID != nil || item.hasAudioContent == false)
            }
        }
        .padding(.vertical, 2)
    }
}
