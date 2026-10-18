// SPDX-License-Identifier: GPL-3.0-or-later
import SwiftUI

struct ABSConnectionsSettingsView: View {
    @Environment(PlayerModel.self) private var model

    @State private var baseURL = ""
    @State private var username = ""
    @State private var password = ""
    @State private var connected: ABSServerRecord?
    @State private var isConnecting = false
    @State private var errorMessage: String?
    @State private var warningMessage: String?
    @State private var browseDestination: BrowseDestination?
    @State private var activeBrowseModel: ABSBrowseModel?
    @State private var pendingTrust: PendingTrust?
    @State private var pendingPlaintextConnection: PlaintextConnectionWarning?

    private struct PendingTrust: Identifiable {
        let id = UUID()
        let host: String
        let sha256: String
    }

    private struct PlaintextConnectionWarning: Identifiable {
        let id = UUID()
        let url: URL

        var displayHost: String {
            if let host = url.host, let port = url.port {
                "\(host):\(port)"
            } else {
                url.host ?? url.absoluteString
            }
        }
    }

    private struct BrowseDestination: Identifiable {
        let id = UUID()
        let model: ABSBrowseModel
    }

    var body: some View {
        Form {
            if let server = connected {
                ABSConnectedServerSection(
                    server: server,
                    browse: presentBrowse,
                    signOut: signOut)
            } else {
                ABSAddServerSection(
                    baseURL: $baseURL,
                    username: $username,
                    password: $password,
                    isConnecting: isConnecting,
                    connect: connect)
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                } header: {
                    Text("Error")
                }
            }

            if let warningMessage {
                Section {
                    Text(warningMessage).foregroundStyle(.orange)
                } header: {
                    Text("Warning")
                }
            }
        }
        .navigationTitle("Connections")
        .task { connected = (try? model.absServerDAO?.current()) ?? nil }
        .sheet(item: $browseDestination, onDismiss: cancelBrowse) { destination in
            ABSBrowseView(browseModel: destination.model) { book in
                model.openAudiobookshelfBook(book)
                cancelBrowse()
                browseDestination = nil
            }
        }
        .alert(
            "Self-Signed Certificate",
            isPresented: Binding(
                get: { pendingTrust != nil },
                set: { if !$0 { pendingTrust = nil } }),
            presenting: pendingTrust
        ) { trust in
            Button("Trust and Connect") { Task { await trustAndConnect(trust) } }
            Button("Cancel", role: .cancel) { pendingTrust = nil }
        } message: { trust in
            Text(
                """
                "\(trust.host)" presented a self-signed certificate.

                SHA-256:
                \(ABSCertificateFingerprint.display(trust.sha256))

                Only trust it if you recognize this fingerprint.
                """)
        }
        .alert(
            "Send Credentials Over Plain HTTP?",
            isPresented: Binding(
                get: { pendingPlaintextConnection != nil },
                set: { if !$0 { pendingPlaintextConnection = nil } }),
            presenting: pendingPlaintextConnection
        ) { warning in
            Button("Send Over HTTP", role: .destructive) {
                pendingPlaintextConnection = nil
                Task { await connect(to: warning.url) }
            }
            Button("Cancel", role: .cancel) { pendingPlaintextConnection = nil }
        } message: { warning in
            Text(
                "Echo will send your Audiobookshelf username and password to \(warning.displayHost) without transport encryption. Use HTTPS or self-signed HTTPS when possible."
            )
        }
    }

    private func connect() async {
        guard let url = ABSEndpoints.normalizedBaseURL(from: baseURL) else {
            errorMessage = String(localized: "Invalid server URL")
            return
        }
        guard !ABSEndpoints.requiresPlainHTTPConfirmation(url) else {
            pendingPlaintextConnection = PlaintextConnectionWarning(url: url)
            return
        }
        await connect(to: url)
    }

    private func connect(to url: URL, trustingCertificate pinnedSHA256: String? = nil) async {
        isConnecting = true
        errorMessage = nil
        warningMessage = nil
        defer { isConnecting = false }
        do {
            let server = try await model.connectAudiobookshelf(
                baseURL: url, username: username, password: password,
                trustingCertificate: pinnedSHA256)
            connected = server
            password = ""
        } catch let error as ABSError {
            if case .untrustedCertificate(let host, let sha256) = error {
                pendingTrust = PendingTrust(host: host, sha256: sha256)  // password kept for retry
            } else {
                errorMessage = String(localized: "Could not connect: \(error.localizedDescription)")
            }
        } catch {
            errorMessage = String(localized: "Could not connect: \(error.localizedDescription)")
        }
    }

    private func trustAndConnect(_ trust: PendingTrust) async {
        pendingTrust = nil
        guard let url = ABSEndpoints.normalizedBaseURL(from: baseURL) else {
            errorMessage = String(localized: "Invalid server URL")
            return
        }
        await connect(to: url, trustingCertificate: trust.sha256)
    }

    private func presentBrowse() {
        guard let browseModel = model.makeABSBrowseModel() else {
            errorMessage = String(
                localized:
                    "Audiobookshelf browsing is unavailable because Echo could not access the active connection or local library database."
            )
            return
        }
        errorMessage = nil
        activeBrowseModel = browseModel
        browseDestination = BrowseDestination(model: browseModel)
    }

    private func cancelBrowse() {
        activeBrowseModel?.cancelImport()
        activeBrowseModel?.cancel()
        activeBrowseModel = nil
    }

    private func signOut(_ server: ABSServerRecord) async {
        do {
            let result = try await model.disconnectAudiobookshelf(server)
            connected = nil
            errorMessage = nil
            if result.didRemoteRevokeFail {
                warningMessage =
                    model.absRemoteSignOutWarning
                    ?? String(
                        localized:
                            "Echo signed out locally, but Audiobookshelf did not confirm remote sign-out. The server session may remain active until it expires."
                    )
            } else {
                warningMessage = nil
            }
        } catch {
            errorMessage =
                String(
                    localized:
                        "Could not remove the Audiobookshelf server from this device. Try signing out again."
                )
            warningMessage = model.absRemoteSignOutWarning
        }
    }
}

private struct ABSConnectedServerSection: View {
    let server: ABSServerRecord
    let browse: () -> Void
    let signOut: (ABSServerRecord) async -> Void

    var body: some View {
        Section("Connected") {
            LabeledContent("Server", value: server.baseURL)
            LabeledContent("User", value: server.username)
            if server.isPlainHTTP {
                Label("Plain HTTP connection", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("Credentials and audiobook data are not encrypted on this server connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Button("Browse Library", action: browse)
            Button("Sign Out", role: .destructive) {
                Task { await signOut(server) }
            }
        }
    }
}

private struct ABSAddServerSection: View {
    @Binding var baseURL: String
    @Binding var username: String
    @Binding var password: String
    let isConnecting: Bool
    let connect: () async -> Void

    var body: some View {
        Section {
            TextField("Server URL (https://host:13378)", text: $baseURL)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                .autocorrectionDisabled()
            TextField("Username", text: $username)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            SecureField("Password", text: $password)
            Button {
                Task { await connect() }
            } label: {
                ABSConnectButtonLabel(isConnecting: isConnecting)
            }
            .disabled(isConnecting || baseURL.isEmpty || username.isEmpty)
        } header: {
            Text("Add Audiobookshelf Server")
        } footer: {
            Text("Bare hosts use HTTPS. Type http:// only for a local server you trust.")
        }
    }
}

private struct ABSConnectButtonLabel: View {
    let isConnecting: Bool

    var body: some View {
        if isConnecting {
            ProgressView()
        } else {
            Text("Connect")
        }
    }
}
