// SPDX-License-Identifier: GPL-3.0-or-later
import Testing

@testable import Echo

@MainActor struct AlignmentShareConfirmationTests {
    @Test func preparingConfirmationDoesNotUpload() {
        var uploads = 0
        let confirmation = AlignmentShareConfirmation { uploads += 1 }

        #expect(uploads == 0)
        confirmation.cancel()
    }

    @Test func cancellationPreventsUpload() async {
        var uploads = 0
        let confirmation = AlignmentShareConfirmation { uploads += 1 }

        confirmation.cancel()
        await confirmation.confirm()

        #expect(uploads == 0)
    }

    @Test func confirmationUploadsOnlyOnce() async {
        var uploads = 0
        let confirmation = AlignmentShareConfirmation { uploads += 1 }

        await confirmation.confirm()
        await confirmation.confirm()

        #expect(uploads == 1)
    }

    @Test func reentrantConfirmationDoesNotUploadAgain() async {
        var uploads = 0
        final class Holder { weak var confirmation: AlignmentShareConfirmation? }
        let holder = Holder()
        let confirmation = AlignmentShareConfirmation {
            uploads += 1
            if uploads == 1 {
                await holder.confirmation?.confirm()
            }
        }

        holder.confirmation = confirmation
        await confirmation.confirm()

        #expect(uploads == 1)
    }
}
