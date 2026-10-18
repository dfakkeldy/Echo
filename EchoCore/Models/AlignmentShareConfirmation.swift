// SPDX-License-Identifier: GPL-3.0-or-later

@MainActor
final class AlignmentShareConfirmation {
    private let upload: @MainActor () async -> Void

    init(upload: @escaping @MainActor () async -> Void) {
        self.upload = upload
    }

    func cancel() {}

    func confirm() async {
        await upload()
    }
}
