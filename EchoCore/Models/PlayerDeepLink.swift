import Foundation

struct PlayerDeepLink: Equatable, Sendable {
    let time: TimeInterval?

    init?(url: URL) {
        guard url.scheme == "echoaudio", url.host == "play" else {
            return nil
        }

        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let time = components?.queryItems?
            .first(where: { $0.name == "time" })
            .flatMap { $0.value }
            .flatMap(TimeInterval.init)

        self.time = time
    }
}
