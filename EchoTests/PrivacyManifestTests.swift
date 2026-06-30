// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@Suite struct PrivacyManifestTests {
    @Test func targetPrivacyManifestsDeclareNoTrackingOrCollectedData() throws {
        for path in Self.manifestPaths {
            let manifest = try Self.manifest(at: path)

            #expect(manifest["NSPrivacyTracking"] as? Bool == false, "\(path) must not declare tracking.")
            #expect((manifest["NSPrivacyTrackingDomains"] as? [Any])?.isEmpty == true)
            #expect((manifest["NSPrivacyCollectedDataTypes"] as? [Any])?.isEmpty == true)
        }
    }

    @Test func targetPrivacyManifestsDeclareRequiredReasonAPIs() throws {
        for path in Self.manifestPaths {
            let declarations = try Self.requiredReasonAPIDeclarations(in: path)

            #expect(
                Set(declarations.keys) == Set(Self.requiredReasonAPIs.keys),
                "\(path) must declare the complete required-reason API set."
            )
            for (apiType, expectedReasons) in Self.requiredReasonAPIs {
                #expect(
                    declarations[apiType] == expectedReasons,
                    "\(path) must declare \(apiType) with reasons \(expectedReasons.sorted())."
                )
            }
        }
    }

    @Test func productionSourceHasManifestCoverageForRequiredReasonAPISignals() throws {
        let source = try Self.productionSwiftSourceCorpus()

        for (apiType, signals) in Self.requiredReasonAPISourceSignals {
            #expect(
                signals.contains { source.contains($0) },
                "Production source scan should detect usage requiring \(apiType)."
            )
            for path in Self.manifestPaths {
                let declarations = try Self.requiredReasonAPIDeclarations(in: path)
                #expect(
                    declarations[apiType] != nil,
                    "\(path) must cover source-scanned required-reason API \(apiType)."
                )
            }
        }
    }

    @Test func appSourceDoesNotLinkTrackingOrAdvertisingSDKs() throws {
        let bannedTokens = [
            "AppTrackingTransparency",
            "ATTrackingManager",
            "ASIdentifierManager",
            "advertisingIdentifier",
            "AdSupport",
            "Amplitude",
            "AppCenter",
            "AppsFlyer",
            "Aptabase",
            "Bugsnag",
            "Crashlytics",
            "Datadog",
            "FirebaseAnalytics",
            "FirebaseCrashlytics",
            "GoogleAnalytics",
            "GoogleMobileAds",
            "Adjust",
            "FBSDK",
            "FacebookCore",
            "Instabug",
            "MatomoTracker",
            "Mixpanel",
            "NewRelic",
            "PostHog",
            "Rollbar",
            "Sentry",
            "TelemetryDeck",
        ]

        for path in Self.sourceScanPaths {
            let text = try Self.source(at: path)
            for token in bannedTokens {
                #expect(!text.contains(token), "\(path) links or references \(token).")
            }
        }
    }

    @Test func macOSAppTargetHasDedicatedPrivacyManifest() throws {
        let project = try Self.source(at: "Echo.xcodeproj/project.pbxproj")
        let targetStart = try #require(
            project.range(of: "AA0100000000000000000020 /* Echo macOS */ = {"),
            "The macOS app target must remain present in the Xcode project."
        )
        let targetSuffix = project[targetStart.lowerBound...]
        let targetEnd = try #require(
            targetSuffix.range(of: "productType = \"com.apple.product-type.application\";"),
            "The macOS app target block must declare an application product type."
        )
        let targetBlock = targetSuffix[..<targetEnd.upperBound]

        #expect(
            targetBlock.contains("AA0100000000000000000010 /* Echo macOS */,"),
            "The macOS app target should include its synchronized source group."
        )
        #expect(
            FileManager.default.fileExists(
                atPath: try Self.root().appending(path: "Echo macOS/PrivacyInfo.xcprivacy").path
            ),
            "The macOS app target must provide a dedicated privacy manifest."
        )
        if let exceptionStart = project.range(
            of: "AA0100000000000000000011 /* Exceptions for \"Echo macOS\" folder in \"Echo macOS\" target */ = {"
        ) {
            let exceptionSuffix = project[exceptionStart.lowerBound...]
            let exceptionEnd = try #require(
                exceptionSuffix.range(of: "target = AA0100000000000000000020 /* Echo macOS */;"),
                "The macOS app synchronized-group exception set should belong to the macOS app target."
            )
            let exceptionBlock = exceptionSuffix[..<exceptionEnd.upperBound]
            #expect(
                !exceptionBlock.contains("PrivacyInfo.xcprivacy"),
                "The macOS privacy manifest must not be excluded from target membership."
            )
        }

        let sharedCoreExceptionStart = try #require(
            project.range(
                of: "718DD03F18BB433E7AD362E2 /* Exceptions for \"EchoCore\" folder in \"Echo macOS\" target */ = {"
            ),
            "The macOS app target should define EchoCore membership exceptions."
        )
        let sharedCoreExceptionSuffix = project[sharedCoreExceptionStart.lowerBound...]
        let sharedCoreExceptionEnd = try #require(
            sharedCoreExceptionSuffix.range(of: "target = AA0100000000000000000020 /* Echo macOS */;"),
            "The EchoCore exception set should belong to the macOS app target."
        )
        let sharedCoreExceptionBlock = sharedCoreExceptionSuffix[..<sharedCoreExceptionEnd.upperBound]
        #expect(
            sharedCoreExceptionBlock.contains("PrivacyInfo.xcprivacy"),
            "The macOS app target must not also copy the shared EchoCore privacy manifest."
        )
    }

    @Test func onnxModelSizeCheckAvoidsBroadFileMetadataAPI() throws {
        let source = try Self.source(at: "EchoCore/Services/Narration/OnnxKokoroEngine.swift")

        #expect(!source.contains("attributesOfItem(atPath:"))
        #expect(source.contains("resourceValues(forKeys: [.fileSizeKey])"))
    }

    private static let manifestPaths = [
        "EchoCore/PrivacyInfo.xcprivacy",
        "Echo macOS/PrivacyInfo.xcprivacy",
        "Echo Watch App/PrivacyInfo.xcprivacy",
        "Echo Widget/PrivacyInfo.xcprivacy",
    ]

    private static let requiredReasonAPIs: [String: Set<String>] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": ["CA92.1", "1C8F.1"],
        "NSPrivacyAccessedAPICategoryFileTimestamp": ["C617.1", "3B52.1"],
        "NSPrivacyAccessedAPICategoryDiskSpace": ["85F4.1"],
    ]

    private static let requiredReasonAPISourceSignals: [String: [String]] = [
        "NSPrivacyAccessedAPICategoryUserDefaults": [
            "UserDefaults",
            "AppGroupDefaults",
        ],
        "NSPrivacyAccessedAPICategoryFileTimestamp": [
            "contentsOfDirectory(",
            "contentsOfDirectory(atPath:",
        ],
        "NSPrivacyAccessedAPICategoryDiskSpace": [
            ".fileSizeKey",
            "attributesOfFileSystem",
            "systemFreeSize",
        ],
    ]

    private static let productionSourceRoots = [
        "EchoCore",
        "Echo macOS",
        "Echo Watch App",
        "Echo Widget",
        "Tools",
    ]

    private static let sourceScanPaths = [
        "Echo.xcodeproj/project.pbxproj",
        "Echo.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
    ]

    private static func manifest(at path: String) throws -> [String: Any] {
        let url = try root().appending(path: path)
        let data = try Data(contentsOf: url)
        return try #require(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
            "\(path) is not a property-list dictionary."
        )
    }

    private static func requiredReasonAPIDeclarations(in path: String) throws -> [String: Set<String>] {
        let manifest = try Self.manifest(at: path)
        let accessedAPIs = try #require(
            manifest["NSPrivacyAccessedAPITypes"] as? [[String: Any]],
            "\(path) must declare required-reason API usage."
        )

        var declarations: [String: Set<String>] = [:]
        for api in accessedAPIs {
            let type = try #require(
                api["NSPrivacyAccessedAPIType"] as? String,
                "\(path) has a required-reason API entry without a type."
            )
            let reasons = Set(
                try #require(
                    api["NSPrivacyAccessedAPITypeReasons"] as? [String],
                    "\(path) must list reasons for \(type)."
                )
            )
            #expect(declarations[type] == nil, "\(path) must not duplicate \(type).")
            declarations[type] = reasons
        }
        return declarations
    }

    private static func source(at path: String) throws -> String {
        let url = try root().appending(path: path)
        return try String(contentsOf: url, encoding: .utf8)
    }

    private static func productionSwiftSourceCorpus() throws -> String {
        let root = try root()
        let manager = FileManager.default
        var corpus = ""

        for sourceRoot in productionSourceRoots {
            let url = root.appending(path: sourceRoot)
            guard let enumerator = manager.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

            for case let fileURL as URL in enumerator where fileURL.pathExtension == "swift" {
                let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
                guard values.isRegularFile == true else { continue }
                corpus += try String(contentsOf: fileURL, encoding: .utf8)
                corpus += "\n"
            }
        }

        return corpus
    }

    private static func root() throws -> URL {
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()

        while directory.path != "/" {
            let candidate = directory.deletingLastPathComponent()
            if FileManager.default.fileExists(
                atPath: candidate.appending(path: "Echo.xcodeproj").path
            ) {
                return candidate
            }
            directory.deleteLastPathComponent()
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
