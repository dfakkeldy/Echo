// SPDX-License-Identifier: GPL-3.0-or-later
import CarPlay

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var manager: CarPlayManager?

    // MARK: - CPTemplateApplicationSceneDelegate

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        let manager = CarPlayManager()
        manager.connect(interfaceController)
        self.manager = manager
    }

    func templateApplicationScene(
        _ templateApplicationScene: CPTemplateApplicationScene,
        didDisconnectInterfaceController interfaceController: CPInterfaceController
    ) {
        // The previous `didDisconnect:` label matched no protocol requirement, so
        // the framework never called it and CarPlay teardown never ran (§4.2).
        manager?.disconnect()
        self.manager = nil
    }
}
