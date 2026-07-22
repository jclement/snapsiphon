import UIKit

/// Home Screen quick-action plumbing. SwiftUI has no first-class API for
/// UIApplicationShortcutItem, so a minimal AppDelegate/SceneDelegate pair
/// captures the action (cold launch or warm resume) into `QuickActions.pending`,
/// and RootView consumes it when the scene becomes active.
@MainActor
enum QuickActions {
    static let backupNow = "ca.straybits.snapsiphon.backupNow"
    static var pending: String?

    /// Consume-and-clear: returns true once per triggered action.
    static func takeBackupRequest() -> Bool {
        guard pending == backupNow else { return false }
        pending = nil
        return true
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        let config = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        config.delegateClass = SceneDelegate.self
        return config
    }
}

final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    // Cold launch from a quick action.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        if let item = connectionOptions.shortcutItem {
            Task { @MainActor in QuickActions.pending = item.type }
        }
    }

    // Warm resume from a quick action.
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        Task { @MainActor in QuickActions.pending = shortcutItem.type }
        completionHandler(true)
    }
}
