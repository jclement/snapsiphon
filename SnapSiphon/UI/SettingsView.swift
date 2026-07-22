import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: BackupEngine
    // Observe directly so the recipient count refreshes the moment a key is
    // added/removed (SettingsView otherwise only observes `engine`).
    @ObservedObject private var keyManager = AgeKeyManager.shared
    /// Identifiable wrapper so the viewer sheet is item-driven — presenting via
    /// a separate Bool raced the @State script and could show an empty sheet
    /// (grey screen) when the closure evaluated before the script landed.
    struct ScriptDocument: Identifiable {
        let id = UUID()
        let text: String
    }

    @State private var showRestoreScriptWarning = false
    @State private var restoreScript: ScriptDocument?
    @State private var writingManifest = false
    @State private var manifestStatus: String?

    var body: some View {
        NavigationStack {
            if engine.isConfigured && !engine.settingsUnlocked {
                lockedView
            } else {
                settingsContent
            }
        }
    }

    /// One Face ID at the door covers everything behind it — keys, storage,
    /// deletions, restore script, reset. Re-locks when the app backgrounds.
    /// (Secret reveal and restore-script export still prompt separately —
    /// those EXPORT secrets rather than merely changing settings.)
    private var lockedView: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 54)).foregroundStyle(Theme.brandGradient)
            Text("Settings locked")
                .font(Theme.rounded(22, weight: .bold)).foregroundStyle(Theme.textPrimary)
            Text("Keys, storage, and recovery settings are protected so no one can quietly redirect your backups or add their own key.")
                .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                .multilineTextAlignment(.center).padding(.horizontal, 28)
            PrimaryButton(title: "Unlock", systemImage: "faceid") {
                Task { await unlockSettings() }
            }
            .padding(.horizontal, 60).padding(.top, 8)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.canvas.ignoresSafeArea())
        .task { await unlockSettings() }   // prompt immediately on entering the tab
    }

    private func unlockSettings() async {
        if await DeviceAuth.authenticate(reason: "Unlock SnapSiphon settings") {
            engine.settingsUnlocked = true
        }
    }

    private var settingsContent: some View {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    SectionHeader(caption: "Tune everything", title: "Settings")

                    setupLinks

                    knobGroup("What to back up") {
                        ToggleRow(title: "Photos", subtitle: "Include images (HEIC, JPEG, RAW).",
                                  isOn: $engine.settings.includePhotos)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Videos", subtitle: "Include video files — these are the big ones.",
                                  isOn: $engine.settings.includeVideos)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Favorites only", subtitle: "Skip anything you haven't hearted.",
                                  isOn: $engine.settings.favoritesOnly)
                    }

                    knobGroup("Speed & concurrency") {
                        SliderRow(title: "Parallel uploads",
                                  subtitle: "How many files travel at once. Changes apply live as files finish.",
                                  value: Binding(
                                    get: { Double(engine.settings.parallelUploads) },
                                    set: { engine.settings.parallelUploads = Int($0) }),
                                  range: 1...8) { "\(Int($0))" }
                        Divider().overlay(Theme.hairline)
                        SliderRow(title: "Speed limit",
                                  subtitle: "Cap upload throughput. 0 = unlimited.",
                                  value: $engine.settings.speedLimitMBps,
                                  range: BackupSettings.speedRange, step: 1) {
                            $0 == 0 ? "∞" : String(format: "%.0f MB/s", $0)
                        }
                    }

                    knobGroup("Conditions") {
                        ToggleRow(title: "Wi-Fi only", subtitle: "Never upload over cellular.",
                                  isOn: $engine.settings.wifiOnly)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Pause on low battery",
                                  subtitle: "Hold uploads below \(Int(engine.settings.lowBatteryThreshold * 100))%.",
                                  isOn: $engine.settings.pauseOnLowBattery)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Keep screen on",
                                  subtitle: "Prevent auto-lock while uploading.",
                                  isOn: $engine.settings.keepScreenOnWhileUploading)
                    }

                    knobGroup("Privacy & safety") {
                        ToggleRow(title: "Encrypt filenames",
                                  subtitle: "Store objects under hashed names so the bucket leaks nothing.",
                                  isOn: $engine.settings.encryptFilenames)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Verify before upload",
                                  subtitle: "HEAD-check each object first. Safer, slower.",
                                  isOn: $engine.settings.verifyRemoteBeforeUpload)
                    }

                    knobGroup("Deletions") {
                        Text("Photos you delete on-device are always marked deleted in the encrypted manifest, so restores skip them (a disaster restore can still recover un-purged ones with --all).")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Purge deleted backups",
                                  subtitle: "Also free the storage: best-effort removal of deleted photos' blobs after the grace period. Off = blobs are kept forever (marked only).",
                                  isOn: $engine.settings.propagateDeletes)
                        if engine.settings.propagateDeletes {
                            Divider().overlay(Theme.hairline)
                            SliderRow(title: "Purge grace period",
                                      subtitle: "Accident window: erase iCloud by mistake and get it back within this many days → nothing is purged.",
                                      value: Binding(
                                        get: { Double(engine.settings.deleteGraceDays) },
                                        set: { engine.settings.deleteGraceDays = Int($0) }),
                                      range: 7...180, step: 1) { "\(Int($0))d" }
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "info.circle.fill")
                                    .foregroundStyle(Theme.teal).font(.system(size: 13))
                                Text("Blobs are freed only after the grace period AND once Object Lock retention expires, whichever is longer. Photos that reappear are un-marked automatically. A purged blob also drops out of the manifest.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.teal.opacity(0.10)))
                        }
                    }

                    knobGroup("Restore manifest") {
                        ToggleRow(title: "Keep encrypted manifest",
                                  subtitle: "Store an age-encrypted key→filename map in the bucket so a bucket-only restore can rename everything back.",
                                  isOn: $engine.settings.keepBucketManifest)
                        Divider().overlay(Theme.hairline)
                        Button {
                            Task {
                                writingManifest = true
                                manifestStatus = nil
                                switch await engine.writeManifest() {
                                case .success(let r):
                                    manifestStatus = "✓ Wrote \(Format.count(r.count)) item\(r.count == 1 ? "" : "s") · \(Format.bytes(r.bytes)) encrypted"
                                case .failure(let error):
                                    manifestStatus = "✗ \(error.localizedDescription)"
                                }
                                writingManifest = false
                            }
                        } label: {
                            HStack {
                                if writingManifest {
                                    ProgressView().tint(Theme.teal)
                                } else {
                                    Image(systemName: "doc.badge.arrow.up")
                                }
                                Text(writingManifest ? "Writing…" : "Write manifest now")
                                    .font(Theme.rounded(16, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(engine.isConfigured ? Theme.teal : Theme.textTertiary)
                        }
                        .disabled(!engine.isConfigured || engine.phase.isActive || writingManifest)
                        if let manifestStatus {
                            Text(manifestStatus)
                                .font(Theme.mono(12))
                                .foregroundStyle(manifestStatus.hasPrefix("✓") ? .green : .red)
                        }
                    }

                    knobGroup("Verify backups") {
                        Button {
                            Task { await engine.verifyBackups() }
                        } label: {
                            HStack {
                                if engine.verifying {
                                    ProgressView().tint(Theme.teal)
                                } else {
                                    Image(systemName: "checkmark.shield")
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.verifying ? "Verifying…" : "Verify all backups")
                                        .font(Theme.rounded(16, weight: .medium))
                                    Text("Egress-free: lists the bucket and checks every file exists with the right size and checksum (stored MD5 vs ETag). Anything missing is re-queued.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .foregroundStyle(engine.isConfigured ? Theme.teal : Theme.textTertiary)
                        }
                        .disabled(!engine.isConfigured || engine.phase.isActive || engine.verifying)
                        if let status = engine.verifyStatus {
                            Text(status)
                                .font(Theme.mono(12))
                                .foregroundStyle(status.hasPrefix("✓") ? .green
                                                 : status.hasPrefix("✗") ? .red : Theme.textSecondary)
                        }
                    }

                    knobGroup("Disaster recovery") {
                        Button { showRestoreScriptWarning = true } label: {
                            HStack {
                                Image(systemName: "cross.case.fill")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Restore script").font(Theme.rounded(16, weight: .medium))
                                    Text("A single Python file with your bucket credentials\(keyManager.hasIdentity ? " and age secret" : "") baked in — run it on a laptop to rebuild the whole archive. Face ID, then review & copy.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .foregroundStyle(engine.isConfigured ? Theme.teal : Theme.textTertiary)
                        }
                        .disabled(!engine.isConfigured)
                    }

                    knobGroup("Automation") {
                        ToggleRow(title: "Back up in the background",
                                  subtitle: "iOS grants short windows (usually overnight, charging, on Wi-Fi) to upload new photos while the app is closed. Best-effort by design.",
                                  isOn: $engine.settings.backgroundBackup)
                        Divider().overlay(Theme.hairline)
                        SliderRow(title: "Remind me",
                                  subtitle: "Notify if no backup has run for this many days. Tapping the notification opens the app (pairs well with auto back up).",
                                  value: Binding(
                                    get: { Double(engine.settings.reminderDays) },
                                    set: { engine.settings.reminderDays = Int($0) }),
                                  range: 0...14, step: 1) { $0 == 0 ? "Off" : "\(Int($0))d" }
                            .onChange(of: engine.settings.reminderDays) { _, _ in
                                engine.rescheduleReminder()
                            }
                    }

                    knobGroup("Scanning") {
                        ToggleRow(title: "Auto back up on open",
                                  subtitle: "Start a backup when the app opens, if the last run finished more than 30 minutes ago.",
                                  isOn: $engine.settings.autoStartOnLaunch)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Fast scan",
                                  subtitle: "Only check photos newer than the last scan. Much faster on big libraries.",
                                  isOn: $engine.settings.incrementalScan)
                        Divider().overlay(Theme.hairline)
                        Button {
                            Task { await engine.deepScan() }
                        } label: {
                            HStack {
                                if engine.phase == .scanning {
                                    ProgressView().tint(Theme.teal)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath")
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(engine.phase == .scanning
                                         ? "Scanning… \(Format.count(engine.scanChecked)) checked"
                                         : "Deep scan")
                                        .font(Theme.rounded(16, weight: .medium))
                                        .contentTransition(.numericText())
                                    Text("Re-check the entire library, ignoring the fast-scan mark. Use after importing older photos.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .foregroundStyle(Theme.teal)
                        }
                        .disabled(engine.phase.isActive)
                        if let status = engine.scanStatus, engine.phase != .scanning {
                            Text(status)
                                .font(Theme.mono(12))
                                .foregroundStyle(.green)
                        }
                    }

                    knobGroup("Maintenance") {
                        Button(role: .destructive) {
                            engine.resetIndex()
                        } label: {
                            HStack {
                                Image(systemName: "trash")
                                Text("Reset local index").font(Theme.rounded(16, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(.red)
                        }
                    }

                    Text("SnapSiphon v1.0 · age + S3 · your keys, your bucket")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .padding(16)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationBarHidden(true)
            .alert("Restore script", isPresented: $showRestoreScriptWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Continue") {
                    Task {
                        // Face ID / passcode prompt happens inside buildRestoreScript.
                        if let script = await engine.buildRestoreScript() {
                            restoreScript = ScriptDocument(text: script)
                        }
                    }
                }
            } message: {
                Text("This builds a single Python file containing your bucket credentials\(keyManager.hasIdentity ? " AND this phone's secret key" : "") in plaintext — enough to rebuild your entire archive on a laptop. After Face ID you can review the script before copying it. Store it like a password.")
            }
            .sheet(item: $restoreScript) { doc in
                RestoreScriptViewer(script: doc.text)
            }
    }

    private var keySubtitle: String {
        let n = keyManager.recipients.count
        return n == 0 ? "Not set" : "\(n) recipient\(n == 1 ? "" : "s")"
    }

    private var setupLinks: some View {
        VStack(spacing: 12) {
            NavigationLink { KeysView() } label: {
                setupRow(icon: "key.fill",
                         title: "Encryption key",
                         subtitle: keySubtitle,
                         ok: keyManager.isConfigured)
            }
            NavigationLink { StorageSetupView() } label: {
                setupRow(icon: "externaldrive.connected.to.line.below.fill",
                         title: "Storage bucket",
                         subtitle: engine.s3Config.isComplete ? "\(engine.s3Config.provider.title) · \(engine.s3Config.bucket)" : "Not set",
                         ok: engine.s3Config.isComplete && S3CredentialStore.hasCredentials)
            }
        }
    }

    private func setupRow(icon: String, title: String, subtitle: String, ok: Bool) -> some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18)).foregroundStyle(Theme.brandGradient)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.rounded(16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ok ? .green : Theme.textTertiary)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    private func knobGroup<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(Theme.mono(11, weight: .medium)).tracking(1.5)
                .foregroundStyle(Theme.teal)
            Card {
                VStack(alignment: .leading, spacing: 14) { content() }
            }
        }
    }
}
