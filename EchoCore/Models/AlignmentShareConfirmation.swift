// SPDX-License-Identifier: GPL-3.0-or-later

@MainActor
final class AlignmentShareConfirmation {
    private var upload: (@MainActor () async -> Void)?

    init(upload: @escaping @MainActor () async -> Void) {
        self.upload = upload
    }

    func cancel() {
        upload = nil
    }

    func confirm() async {
        guard let upload else { return }
        // Consume the request before suspension so repeated or reentrant taps cannot upload again.
        self.upload = nil
        await upload()
    }
}
