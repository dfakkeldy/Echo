// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Observation

@MainActor
@Observable
final class AnthologyListViewModel {
    private(set) var projects: [AnthologyRecord] = []
    private(set) var isLoading = false
    private(set) var userMessage: String?

    @ObservationIgnored private let load: () async throws -> [AnthologyRecord]
    @ObservationIgnored private var reloadGeneration = 0

    init(load: @escaping () async throws -> [AnthologyRecord]) {
        self.load = load
    }

    convenience init(service: AnthologyService) {
        self.init {
            try await Task.detached { try service.projects() }.value
        }
    }

    func reload() async {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        isLoading = true
        do {
            let loaded = try await load()
            guard generation == reloadGeneration else { return }
            projects = loaded
            userMessage = nil
        } catch {
            guard generation == reloadGeneration else { return }
            userMessage = "Anthologies could not be loaded. Try again."
        }
        guard generation == reloadGeneration else { return }
        isLoading = false
    }

    func dismissMessage() {
        userMessage = nil
    }
}
