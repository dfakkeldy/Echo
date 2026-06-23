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
    @State private var showingBrowse = false
    @State private var pendingTrust: PendingTrust?

    private struct PendingTrust: Identifiable {
        let id = UUID()
        let host: String
        let sha256: String
    }

    var body: some View {
        Form {
            if let server = connected {
                Section("Connected") {
                    LabeledContent("Server", value: server.baseURL)
                    LabeledContent("User", value: server.username)
                    Button("Browse Library") { showingBrowse = true }
                    Button("Sign Out", role: .destructive) {
                        Task { await signOut(server) }
                    }
                }
            } else {
                Section("Add Audiobookshelf Server") {
                    TextField("Server URL (http://host:13378)", text: $baseURL)
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
                        if isConnecting { ProgressView() } else { Text("Connect") }
                    }
                    .disabled(isConnecting || baseURL.isEmpty || username.isEmpty)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                } header: {
                    Text("Error")
                }
            }
        }
        .navigationTitle("Connections")
        .task { connected = (try? model.absServerDAO?.current()) ?? nil }
        .sheet(isPresented: $showingBrowse) { ABSBrowseView() }
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
    }

    private func connect() async {
        guard let url = ABSEndpoints.normalizedBaseURL(from: baseURL) else {
            errorMessage = "Invalid server URL"
            return
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let server = try await model.connectAudiobookshelf(
                baseURL: url, username: username, password: password)
            connected = server
            password = ""
        } catch let error as ABSError {
            if case .untrustedCertificate(let host, let sha256) = error {
                pendingTrust = PendingTrust(host: host, sha256: sha256)  // password kept for retry
            } else {
                errorMessage = "Could not connect: \(error.localizedDescription)"
            }
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
        }
    }

    private func trustAndConnect(_ trust: PendingTrust) async {
        pendingTrust = nil
        guard let url = ABSEndpoints.normalizedBaseURL(from: baseURL) else {
            errorMessage = "Invalid server URL"
            return
        }
        isConnecting = true
        errorMessage = nil
        defer { isConnecting = false }
        do {
            let server = try await model.connectAudiobookshelf(
                baseURL: url, username: username, password: password,
                trustingCertificate: trust.sha256)
            connected = server
            password = ""
        } catch {
            errorMessage = "Could not connect: \(error.localizedDescription)"
        }
    }

    private func signOut(_ server: ABSServerRecord) async {
        await model.disconnectAudiobookshelf(server)
        connected = nil
    }
}
