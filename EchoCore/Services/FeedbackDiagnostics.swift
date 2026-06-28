// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
#if os(iOS)
    import UIKit
#endif

struct FeedbackDiagnostics: Equatable, Sendable {
    var appVersion: String
    var buildNumber: String
    var platform: String
    var osVersion: String
    var deviceModel: String
    var localeIdentifier: String
    var timeZoneIdentifier: String
    var debugLoggingEnabled: Bool

    var formattedString: String {
        """
        App: \(appVersion) (\(buildNumber))
        Platform: \(platform)
        OS: \(osVersion)
        Device: \(deviceModel)
        Locale: \(localeIdentifier)
        Time Zone: \(timeZoneIdentifier)
        Verbose Diagnostic Logging: \(debugLoggingEnabled ? "On" : "Off")
        """
    }
}

enum FeedbackDiagnosticsCollector {
    @MainActor
    static func collect(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        locale: Locale = .current,
        timeZone: TimeZone = .current,
        debugLoggingEnabled: Bool = false
    ) -> FeedbackDiagnostics {
        let metadata = AppBuildMetadata(bundle: bundle)
        return FeedbackDiagnostics(
            appVersion: metadata.marketingVersion,
            buildNumber: metadata.buildNumber,
            platform: platformName(processInfo: processInfo),
            osVersion: osVersion(processInfo: processInfo),
            deviceModel: deviceModel(),
            localeIdentifier: locale.identifier,
            timeZoneIdentifier: timeZone.identifier,
            debugLoggingEnabled: debugLoggingEnabled
        )
    }

    private static func platformName(processInfo: ProcessInfo) -> String {
        #if os(iOS)
            return UIDevice.current.systemName
        #elseif os(macOS)
            return "macOS"
        #elseif os(watchOS)
            return "watchOS"
        #elseif os(tvOS)
            return "tvOS"
        #elseif os(visionOS)
            return "visionOS"
        #else
            return processInfo.operatingSystemVersionString
        #endif
    }

    private static func osVersion(processInfo: ProcessInfo) -> String {
        #if os(iOS)
            return UIDevice.current.systemVersion
        #else
            let version = processInfo.operatingSystemVersion
            return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        #endif
    }

    private static func deviceModel() -> String {
        #if os(iOS)
            return UIDevice.current.model
        #elseif os(macOS)
            return Host.current().localizedName ?? "Mac"
        #else
            return "Unknown"
        #endif
    }
}
