// SPDX-License-Identifier: GPL-3.0-or-later
#if canImport(UIKit)
    import Photos
    import UIKit

    /// Add-only Photos saving with an explicit permission flow. Replaces the
    /// fire-and-forget `UIImageWriteToSavedPhotosAlbum` path: authorization is
    /// requested up front (.addOnly — the narrowest scope), denial is surfaced
    /// to the caller instead of swallowed, and failures are reported.
    ///
    /// DI follows the DatabaseService convention: concrete type + closure
    /// injection, no protocol (the test double injects the closures).
    @MainActor
    final class PhotoLibrarySaver {
        enum SaveOutcome: Equatable {
            case saved, denied, failed
        }

        private let requestAuthorization: () async -> PHAuthorizationStatus
        private let performSave: (UIImage) async throws -> Void

        init(
            requestAuthorization: @escaping () async -> PHAuthorizationStatus = {
                await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            },
            performSave: @escaping (UIImage) async throws -> Void = { image in
                try await PHPhotoLibrary.shared().performChanges {
                    PHAssetCreationRequest.creationRequestForAsset(from: image)
                }
            }
        ) {
            self.requestAuthorization = requestAuthorization
            self.performSave = performSave
        }

        func save(_ image: UIImage) async -> SaveOutcome {
            switch await requestAuthorization() {
            case .authorized, .limited:
                do {
                    try await performSave(image)
                    return .saved
                } catch {
                    return .failed
                }
            default:
                return .denied
            }
        }
    }
#endif
