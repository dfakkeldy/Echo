import Foundation

final class DataResourcesUtil {
    private init() {}

    private static func resourceURL(_ name: String) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"], !dir.isEmpty {
            let c = URL(fileURLWithPath: dir).appendingPathComponent("\(name).json")
            if FileManager.default.fileExists(atPath: c.path) { return c }
        }
        return Bundle.main.url(forResource: name, withExtension: "json")
    }

    static func loadGold(british: Bool) -> [String: Any] {
        let filename = british ? "gb_gold" : "us_gold"

        guard let url = resourceURL(filename),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            return [:]
        }

        return json
    }

    static func loadSilver(british: Bool) -> [String: Any] {
        let filename = british ? "gb_silver" : "us_silver"

        guard let url = resourceURL(filename),
            let data = try? Data(contentsOf: url),
            let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        else {
            return [:]
        }

        return json
    }
}
