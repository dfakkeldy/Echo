import Foundation

/// Manages security-scoped resource access grants for folder and file URLs.
/// Used by PlayerModel to maintain access to user-selected files outside the app sandbox.
final class SecurityScopeManager {
    private var hasSelectionAccess: Bool = false
    private var selectionURL: URL?

    private var hasFileAccess: Bool = false
    private var fileURL: URL?

    deinit {
        stopAll()
    }

    /// Starts accessing the security-scoped resource for the given selection URL.
    func startSelection(url: URL) {
        guard !hasSelectionAccess else { return }
        selectionURL = url
        hasSelectionAccess = url.startAccessingSecurityScopedResource()
    }

    /// Stops the selection security-scoped access and optionally starts a new one.
    func stopSelection() {
        guard hasSelectionAccess, let url = selectionURL else { return }
        url.stopAccessingSecurityScopedResource()
        hasSelectionAccess = false
        selectionURL = nil
    }

    /// Starts accessing the security-scoped resource for the given file URL.
    func startFile(url: URL) {
        guard !hasFileAccess else { return }
        fileURL = url
        hasFileAccess = url.startAccessingSecurityScopedResource()
    }

    /// Stops the current file security-scoped access.
    func stopFile() {
        guard hasFileAccess, let url = fileURL else { return }
        url.stopAccessingSecurityScopedResource()
        hasFileAccess = false
        fileURL = nil
    }

    /// Stops both selection and file security-scoped access grants.
    func stopAll() {
        stopFile()
        stopSelection()
    }
}
