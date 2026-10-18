// SPDX-License-Identifier: GPL-3.0-or-later
import Foundation
import Testing

@testable import Echo

/// Guards the macOS App-level sheets against the crash fixed alongside these
/// tests: opening View ▸ Article Workshop… trapped instantly in
/// `EnvironmentBox.update` with "No Observable object of type SettingsManager
/// found".
///
/// The cause is modifier ordering, not a missing scene. `.environment(x)` writes
/// `x` into *its content's* subtree, and `Echo_macOSApp` applies all six
/// `.environment(...)` calls to `MacTriPaneView()` and then chains the `.sheet`
/// modifiers after them. Each `.sheet` therefore sits outside every environment
/// write and captures the bare scene-root environment, so sheet content sees
/// none of the app's services. `@Environment(SomeObservable.self)` is updated
/// eagerly, before `body` runs, so such a view traps on open even when it only
/// reads the value conditionally.
///
/// Two disciplines make an App-level sheet safe, and both are accepted here:
/// hand the dependency in through the initializer (what the four crashing views
/// now do), or re-inject it inside the sheet closure (what `MacBatchQueueView`
/// already did, which is why it never crashed). The invariant below is that a
/// sheet's content view may read environment observables *only* when its own
/// closure re-injects — anything else is the crash.
///
/// Source-scanning, because the `Echo macOS` target is not compiled into
/// EchoTests (see `MacSource`).
struct MacSheetEnvironmentInjectionTests {

    /// Views the scanner must find under the App's `.sheet` modifiers. Pinning
    /// them stops a scanner that silently matches nothing from turning every
    /// assertion below into a vacuous pass.
    private static let knownAppSheetContent: Set<String> = [
        "MacBatchQueueView",
        "MacAnkiExportView",
        "MacAudioExportView",
        "MacVideoExportView",
        "MacArticleWorkshopView",
    ]

    @Test("Scanner finds every sheet the App presents")
    func scannerFindsAppSheetContent() throws {
        let app = try MacSource.read("Echo_macOSApp.swift")
        let found = Set(MacSheetScan.closures(in: app).flatMap(MacSheetScan.macViewTypes(in:)))

        #expect(
            Self.knownAppSheetContent.isSubset(of: found),
            "Sheet scan missed: \(Self.knownAppSheetContent.subtracting(found).sorted())")
    }

    @Test("App-level sheet content never reads an uninjected environment observable")
    func appSheetContentHasNoUninjectedEnvironmentDependency() throws {
        let app = try MacSource.read("Echo_macOSApp.swift")

        for closure in MacSheetScan.closures(in: app) {
            let reinjects = closure.contains(".environment(")
            for type in MacSheetScan.macViewTypes(in: closure) {
                guard let source = try? MacSource.read("Views/\(type).swift") else { continue }
                let dependencies = MacSheetScan.environmentObservables(in: source)
                guard dependencies.isEmpty == false else { continue }

                #expect(
                    reinjects,
                    """
                    \(type) reads \(dependencies.sorted()) from the environment, but the \
                    sheet presenting it injects nothing. Sheet content does not inherit the \
                    `.environment(...)` writes applied above the `.sheet` modifier, so this \
                    traps on open. Pass the dependency through \(type)'s initializer, or add \
                    `.environment(...)` inside the sheet closure.
                    """)
            }
        }
    }

    @Test("The four crashing views take their dependency through init")
    func crashingViewsUseConstructorInjection() throws {
        let workshop = try MacSource.read("Views/MacArticleWorkshopView.swift")
        #expect(workshop.contains("init(db: DatabaseService, settings: SettingsManager)"))
        #expect(workshop.contains("private let settings: SettingsManager"))

        let anki = try MacSource.read("Views/MacAnkiExportView.swift")
        #expect(anki.contains("let dbService: DatabaseService"))

        // Hoisted: `#expect` decomposes member accesses into non-throwing
        // closures, so a `try` inside the expression fails to compile.
        for path in ["Views/MacAudioExportView.swift", "Views/MacVideoExportView.swift"] {
            let source = try MacSource.read(path)
            #expect(source.contains("let settings: SettingsManager"), "\(path) lost its injection")
        }
    }

    @Test("The App passes each sheet the services its content needs")
    func appPassesDependenciesAtCallSites() throws {
        let app = try MacSource.read("Echo_macOSApp.swift")
        #expect(app.contains("MacArticleWorkshopView(db: dbService, settings: settings)"))
        #expect(app.contains("MacAnkiExportView(dbService: dbService)"))
        #expect(app.contains("databaseWriter: db, settings: settings"))
    }
}
