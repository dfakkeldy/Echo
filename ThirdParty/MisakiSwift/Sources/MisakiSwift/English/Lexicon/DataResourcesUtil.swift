import Foundation

final class DataResourcesUtil {
    private init() {}

    private static func resourceURL(_ name: String) -> URL? {
        if let dir = ProcessInfo.processInfo.environment["ECHO_RESOURCE_DIR"], !dir.isEmpty {
            let c = URL(fileURLWithPath: dir).appendingPathComponent("\(name).json")
            if FileManager.default.fileExists(atPath: c.path) { return c }
        }

        if let bundled = Bundle.main.url(forResource: name, withExtension: "json") {
            return bundled
        }

        let definingBundle = Bundle(for: DataResourcesUtil.self)
        if let bundled = definingBundle.url(forResource: name, withExtension: "json") {
            return bundled
        }

        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<8 {
            let candidate = directory
                .appending(path: "EchoCore")
                .appending(path: "Services")
                .appending(path: "Narration")
                .appending(path: "MisakiResources")
                .appendingPathComponent("\(name).json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }

        return nil
    }

    static func loadGold(british: Bool) -> [String: Any] {
        let filenames = british ? ["gb_gold", "us_gold"] : ["us_gold"]
        return loadResource(named: filenames)
    }

    static func loadSilver(british: Bool) -> [String: Any] {
        let filenames = british ? ["gb_silver", "us_silver"] : ["us_silver"]
        return loadResource(named: filenames)
    }

    private static func loadResource(named filenames: [String]) -> [String: Any] {
        for filename in filenames {
            guard let url = resourceURL(filename),
                let data = try? Data(contentsOf: url),
                let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
            else {
                continue
            }

            return json
        }

        return [:]
    }
}
