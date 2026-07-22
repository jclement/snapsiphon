import SwiftUI

@main
struct SnapSiphonApp: App {
    @StateObject private var engine = BackupEngine()

    init() {
        // Global dark, terminal-ish appearance.
        UITabBar.appearance().backgroundColor = UIColor(Theme.surface)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .preferredColorScheme(.dark)
                .tint(Theme.teal)
        }
    }
}
