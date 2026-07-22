import SwiftUI

struct RootView: View {
    @EnvironmentObject var engine: BackupEngine
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Theme.canvas.ignoresSafeArea()
            TabView {
                DashboardView()
                    .tabItem { Label("Backup", systemImage: "arrow.up.circle.fill") }
                ActivityView()
                    .tabItem { Label("Activity", systemImage: "waveform.path.ecg") }
                SettingsView()
                    .tabItem { Label("Settings", systemImage: "slider.horizontal.3") }
            }
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-lock the settings gate whenever the app leaves the foreground.
            if phase == .background { engine.settingsUnlocked = false }
        }
    }
}
