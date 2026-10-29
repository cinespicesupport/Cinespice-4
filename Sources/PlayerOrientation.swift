import UIKit
import SwiftUI

@MainActor
final class PlayerOrientation: ObservableObject {
    static let shared = PlayerOrientation()
    @Published private(set) var landscape = false
    var mask: UIInterfaceOrientationMask { landscape ? .landscapeRight : .portrait }

    func setLandscape(_ value: Bool, report: @escaping (String) -> Void = { _ in }) {
        let previous = landscape
        landscape = value
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: { $0.activationState == .foregroundActive }) else { return }
        var controller = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController
        while let current = controller {
            current.setNeedsUpdateOfSupportedInterfaceOrientations()
            controller = current.presentedViewController
        }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { [weak self] error in
            Task { @MainActor in self?.landscape = previous; report("Rotation unavailable: \(error.localizedDescription)") }
        }
    }
}

@MainActor
final class CinespiceAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        PlayerOrientation.shared.mask
    }
}
