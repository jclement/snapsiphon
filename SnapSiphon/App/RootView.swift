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
        .task {
            engine.autoBackupIfDue()
        }
        .onChange(of: scenePhase) { _, phase in
            // Re-lock the settings gate whenever the app leaves the foreground.
            if phase == .background {
                engine.settingsUnlocked = false
                engine.scheduleBackgroundBackup()   // request the next overnight window
            }
            // Coming back to the foreground: refresh the "to back up" numbers
            // and kick an auto backup if one is due.
            if phase == .active {
                Task {
                    await engine.refreshLibraryCounts()
                    engine.autoBackupIfDue()
                }
            }
        }
    }
}
