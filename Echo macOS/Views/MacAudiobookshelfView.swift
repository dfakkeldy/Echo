// SPDX-License-Identifier: GPL-3.0-or-later
import Observation
import SwiftUI

/// macOS Audiobookshelf orchestration over the shared, macOS-clean ABS services
/// (AudiobookshelfService / ABSTokenStore / ABSImportService / ABSServerDAO).
/// The iOS `PlayerModel+Audiobookshelf` and ABS views are not part of the macOS
/// target, so macOS drives connection ownership directly. Browsing and imports
/// are delegated to the shared `ABSBrowseModel`. macOS can save multiple ABS
/// servers, switch the active one, and leaves long-lived progress sync to
/// `MacPlayerModel+Audiobookshelf`.
@MainActor
@Observable
final class MacAudiobookshelfViewModel {
    enum Phase {
        case disconnected, connecting, connected
        case addingServer
    }

    var phase: Phase = .disconnected
    var server: ABSServerRecord?
    var savedServers: [ABSServerRecord] = []
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

    var browseModel: ABSBrowseModel?

    @ObservationIgnored private let db: DatabaseService
    @ObservationIgnored private var service: AudiobookshelfService?
    @ObservationIgnored private var connectionIdentity = ABSServerConnectionIdentity()

    init(db: DatabaseService) {
        self.db = db
    }

    // MARK: Lifecycle

    func load() async {
        loadSavedServers()
        guard let record = try? ABSServerDAO(db: db.writer).current() else {
            phase = .disconnected
            return
        }
        server = record
        connectionIdentity.activate(record.id)
        service = makeService(for: record)
        phase = .connected
        if let service {
            installBrowseModel(service: service, serverID: record.id)
            await browseModel?.load()
        }
    }

    private func loadSavedServers() {
        savedServers = (try? ABSServerDAO(db: db.writer).all()) ?? []
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
        let newServerID = connectionIdentity.prepareNewConnection()
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
            let dao = ABSServerDAO(db: db.writer)
            try dao.upsert(record)
            try dao.setActive(newServerID)
            clearBrowseModel()
            service?.invalidate()
            service = svc
            connectionIdentity.activatePendingConnection()
            server = record
            password = ""
            phase = .connected
            loadSavedServers()
            installBrowseModel(service: svc, serverID: newServerID)
            await browseModel?.load()
        } catch let absError as ABSError {
            svc.invalidate()
            phase = server != nil ? .connected : .disconnected
            if case .untrustedCertificate(let h, let sha) = absError {
                pendingCert = PendingCert(host: h, sha256: sha)
            } else {
                errorMessage = absError.errorDescription ?? "Could not connect to the server."
            }
        } catch {
            svc.invalidate()
            phase = server != nil ? .connected : .disconnected
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() async {
        guard let current = server else { return }
        await removeSavedServer(current)
    }

    func beginAddingServer() {
        errorMessage = nil
        discardPendingConnection()
        serverURLText = ""
        username = ""
        password = ""
        phase = .addingServer
    }

    func cancelAddingServer() {
        errorMessage = nil
        discardPendingConnection()
        phase = server != nil ? .connected : .disconnected
    }

    /// Switches the active server to an already-saved one. Does not touch
    /// Keychain tokens — the saved refresh token is reused, so no re-login
    /// is needed.
    func switchTo(_ saved: ABSServerRecord) async {
        errorMessage = nil
        guard let newService = makeService(for: saved) else {
            errorMessage = "Could not reconnect to this server."
            return
        }
        do {
            try ABSServerDAO(db: db.writer).setActive(saved.id)
        } catch {
            newService.invalidate()
            errorMessage = error.localizedDescription
            return
        }
        clearBrowseModel()
        service?.invalidate()
        service = newService
        connectionIdentity.activate(saved.id)
        server = saved
        phase = .connected
        loadSavedServers()
        installBrowseModel(service: newService, serverID: saved.id)
        await browseModel?.load()
    }

    /// Removes a saved server: best-effort remote sign-out if it was the
    /// active one, clears its Keychain tokens, deletes its DB row. Mirrors
    /// the old `disconnect()` but targets a specific server.
    func removeSavedServer(_ saved: ABSServerRecord) async {
        let wasActive = saved.id == connectionIdentity.activeServerID
        if wasActive { clearBrowseModel() }
        if wasActive, let svc = service {
            _ = await svc.signOut()
            svc.invalidate()
        }
        ABSTokenStore(serverID: saved.id).clear()
        try? ABSServerDAO(db: db.writer).delete(saved.id)
        loadSavedServers()
        guard wasActive else { return }
        service = nil
        connectionIdentity.clearActiveConnection()
        server = nil
        phase = .disconnected
    }

    private func installBrowseModel(service: AudiobookshelfService, serverID: String) {
        browseModel = ABSBrowseModel(service: service, db: db, serverID: serverID)
    }

    func cancelBrowseWork() {
        browseModel?.cancelImport()
        browseModel?.cancel()
    }

    func shutdown() {
        clearBrowseModel()
        discardPendingConnection()
        service?.invalidate()
        service = nil
    }

    private func clearBrowseModel() {
        cancelBrowseWork()
        browseModel = nil
    }

    private func discardPendingConnection() {
        if let pendingServerID = connectionIdentity.pendingServerID {
            ABSTokenStore(serverID: pendingServerID).clear()
        }
        connectionIdentity.discardPendingConnection()
    }
}

/// macOS Audiobookshelf connect + browse + download sheet. Reached via
/// File ▸ Connect to Audiobookshelf….
struct MacAudiobookshelfView: View {
    @State private var model: MacAudiobookshelfViewModel
    private let onPlay: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    init(db: DatabaseService, onPlay: @escaping (URL) -> Void) {
        self.onPlay = onPlay
        _model = State(initialValue: MacAudiobookshelfViewModel(db: db))
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            switch model.phase {
            case .disconnected, .addingServer: connectForm
            case .connecting:
                ProgressView("Connecting…").frame(maxWidth: .infinity, maxHeight: .infinity)
            case .connected:
                if let browseModel = model.browseModel {
                    MacAudiobookshelfBrowseView(browseModel: browseModel, onPlay: onPlay)
                } else {
                    ProgressView("Loading Audiobookshelf…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .frame(width: 820, height: 620)
        .padding()
        .task { await model.load() }
        .onDisappear { model.shutdown() }
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
                // Always available while connected — not gated on already having a
                // second saved server, since this is the only entry point that lets
                // you add one. Gating on `count > 1` was a dead end: the count could
                // never reach 2 without going through this button first.
                Button("Switch Server…") { model.beginAddingServer() }
                    .buttonStyle(.borderedProminent)
                Button("Sign Out") { Task { await model.disconnect() } }
                    .buttonStyle(.borderedProminent)
            }
            if model.phase == .addingServer {
                Button("Cancel") { model.cancelAddingServer() }
                    .buttonStyle(.borderedProminent)
            }
            Button("Done", action: close)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
    }

    private var connectForm: some View {
        Form {
            if !model.savedServers.isEmpty {
                Section("Saved Servers") {
                    ForEach(model.savedServers) { saved in
                        savedServerRow(saved)
                    }
                }
            }
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

    private func savedServerRow(_ saved: ABSServerRecord) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.username).fontWeight(saved.isActive ? .semibold : .regular)
                Text(URL(string: saved.baseURL)?.host ?? saved.baseURL)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if saved.isActive {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Button("Connect") { Task { await model.switchTo(saved) } }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
            Button(role: .destructive) {
                Task { await model.removeSavedServer(saved) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }

    private func close() {
        model.shutdown()
        dismiss()
    }
}
