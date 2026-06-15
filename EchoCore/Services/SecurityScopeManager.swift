import Foundation

/// Manages security-scoped resource access grants for folder and file URLs.
/// Used by PlayerModel to maintain access to user-selected files outside the app sandbox.
final class SecurityScopeManager {
    private var hasSelectionAccess: Bool = false
    private var selectionURL: URL?

    private var hasFileAccess: Bool = false
    private var fileURL: URL?

    private var hasParentAccess: Bool = false
    private var parentURL: URL?

    deinit {
        stopAll()
    }

    /// Starts accessing the security-scoped resource for the given selection URL.
    /// - Returns: `true` if access was granted, `false` otherwise (bookmark stale,
    ///            entitlements mismatch, or resource unavailable).
    @discardableResult
    func startSelection(url: URL) -> Bool {
        if hasSelectionAccess {
            if selectionURL == url { return true }
            stopSelection()
        }
        selectionURL = url
        hasSelectionAccess = url.startAccessingSecurityScopedResource()
        return hasSelectionAccess
    }

    /// Stops the selection security-scoped access and optionally starts a new one.
    func stopSelection() {
        guard hasSelectionAccess, let url = selectionURL else { return }
        url.stopAccessingSecurityScopedResource()
        hasSelectionAccess = false
        selectionURL = nil
    }

    /// Starts accessing the security-scoped resource for the given file URL.
    /// - Returns: `true` if access was granted, `false` otherwise.
    @discardableResult
    func startFile(url: URL) -> Bool {
        if hasFileAccess {
            if fileURL == url { return true }
            stopFile()
        }
        fileURL = url
        hasFileAccess = url.startAccessingSecurityScopedResource()
        return hasFileAccess
    }

    /// Stops the current file security-scoped access.
    func stopFile() {
        guard hasFileAccess, let url = fileURL else { return }
        url.stopAccessingSecurityScopedResource()
        hasFileAccess = false
        fileURL = nil
    }

    /// Starts accessing the security-scoped resource for a parent directory.
    /// Used when the user opens a single file (an M4B or a study EPUB) so EPUB
    /// auto-import can enumerate sibling files in the containing folder. Tracked
    /// separately from the selection/file scopes so it is balanced by a matching
    /// `stopParent()` instead of leaking a grant for the process lifetime.
    /// - Returns: `true` if access was granted, `false` otherwise.
    @discardableResult
    func startParent(url: URL) -> Bool {
        if hasParentAccess {
            if parentURL == url { return true }
            stopParent()
        }
        parentURL = url
        hasParentAccess = url.startAccessingSecurityScopedResource()
        return hasParentAccess
    }

    /// Stops the parent-directory security-scoped access.
    func stopParent() {
        guard hasParentAccess, let url = parentURL else { return }
        url.stopAccessingSecurityScopedResource()
        hasParentAccess = false
        parentURL = nil
    }

    /// Stops the selection, file, and parent security-scoped access grants.
    func stopAll() {
        stopFile()
        stopParent()
        stopSelection()
    }
}
