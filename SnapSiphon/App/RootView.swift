import SwiftUI

struct RootView: View {
    @EnvironmentObject var engine: BackupEngine

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
    }
}
