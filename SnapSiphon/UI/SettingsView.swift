import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: BackupEngine
    // Observe directly so the recipient count refreshes the moment a key is
    // added/removed (SettingsView otherwise only observes `engine`).
    @ObservedObject private var keyManager = AgeKeyManager.shared
    @ObservedObject private var premium = PremiumStore.shared
    /// Identifiable wrapper so the viewer sheet is item-driven — presenting via
    /// a separate Bool raced the @State script and could show an empty sheet
    /// (grey screen) when the closure evaluated before the script landed.
    struct ScriptDocument: Identifiable {
        let id = UUID()
        let text: String
    }

    @State private var showRestoreScriptWarning = false
    @State private var restoreScript: ScriptDocument?
    @State private var compacting = false
    @State private var reloadingIndex = false
    @State private var showReloadConfirm = false
    @State private var showPurgeConfirm = false
    @State private var purgePendingCount = 0

    /// Initial cutoff when the toggle is first enabled: Jan 1 2000, i.e.
    /// "everything" — predates any phone photo library.
    private static let cutoffSeed = DateComponents(calendar: .current, year: 2000, month: 1, day: 1).date ?? .distantPast

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
                .font(.system(size: 54)).foregroundStyle(Theme.teal)
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
                        Divider().overlay(Theme.hairline)
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Back up from")
                                    .font(Theme.rounded(15, weight: .medium))
                                    .foregroundStyle(Theme.textPrimary)
                                Spacer()
                                if let cutoff = engine.settings.backupCutoff {
                                    DatePicker("",
                                               selection: Binding(
                                                get: { cutoff },
                                                set: { engine.settings.backupCutoff = Calendar.current.startOfDay(for: $0) }),
                                               in: ...Date(),
                                               displayedComponents: .date)
                                        .labelsHidden()
                                        .tint(Theme.teal)
                                    Button {
                                        engine.settings.backupCutoff = nil
                                    } label: {
                                        Image(systemName: "xmark.circle.fill")
                                            .font(.system(size: 18))
                                            .foregroundStyle(Theme.textTertiary)
                                    }
                                } else {
                                    Button {
                                        // Seeded far in the past, so setting a
                                        // date excludes nothing until it's moved.
                                        engine.settings.backupCutoff = Self.cutoffSeed
                                    } label: {
                                        Text("Everything")
                                            .font(Theme.rounded(14, weight: .medium))
                                            .foregroundStyle(Theme.teal)
                                            .padding(.horizontal, 12).padding(.vertical, 6)
                                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.surfaceHi))
                                    }
                                }
                            }
                            Text(engine.settings.backupCutoff == nil
                                 ? "Will include all photos & videos."
                                 : "Will include only items taken or added after \(engine.settings.backupCutoff!.formatted(date: .abbreviated, time: .omitted)). Earlier items are also left out of the progress ring.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
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
                                  subtitle: "Caps TOTAL upload throughput across all parallel lanes. 0 = unlimited.",
                                  value: $engine.settings.speedLimitMBps,
                                  range: BackupSettings.speedRange, step: 1) {
                            $0 == 0 ? "∞" : String(format: "%.0f MB/s", $0)
                        }
                    }

                    knobGroup("Conditions") {
                        ToggleRow(title: "Wi-Fi only",
                                  subtitle: "New uploads wait for Wi-Fi. A file already mid-upload finishes on the current connection rather than wasting the transfer.",
                                  isOn: $engine.settings.wifiOnly)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Pause on low battery",
                                  subtitle: "No new uploads below \(Int(engine.settings.lowBatteryThreshold * 100))% (unless charging); in-flight files finish.",
                                  isOn: $engine.settings.pauseOnLowBattery)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Keep screen on",
                                  subtitle: "Prevent auto-lock while uploading.",
                                  isOn: $engine.settings.keepScreenOnWhileUploading)
                    }

                    knobGroup("Deletions") {
                        Text("Photos you delete on-device are always recorded as deleted in the encrypted journal, so restores skip them (a disaster restore can still recover un-purged ones with --all).")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Purge deleted backups automatically",
                                  subtitle: "Garbage-collect on every sync: best-effort removal of deleted photos' blobs after the grace period. Off = blobs are kept forever (marked only). Needs a key with delete permission — pointless on append-only buckets until retention expires.",
                                  isOn: Binding(
                                    get: { engine.settings.propagateDeletes },
                                    set: { on in
                                        // Turning this ON can free blobs on the
                                        // very next automatic sync — confirm
                                        // with the real number first.
                                        if on { purgePendingCount = engine.purgeEligibleCount(); showPurgeConfirm = true }
                                        else { engine.settings.propagateDeletes = false }
                                    }))
                        .alert("Enable automatic purge?", isPresented: $showPurgeConfirm) {
                            Button("Enable", role: .destructive) { engine.settings.propagateDeletes = true }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text(purgePendingCount > 0
                                 ? "\(Format.count(purgePendingCount)) deleted backup\(purgePendingCount == 1 ? " is" : "s are") already past the grace period — their storage is freed on the NEXT sync, permanently. Photos deleted more recently stay recoverable until their grace period ends."
                                 : "Nothing is currently past the grace period. From now on, deleted photos' storage is freed automatically once their grace period ends.")
                        }
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
                                Text("Blobs are freed only after the grace period AND once Object Lock retention expires, whichever is longer. Photos that reappear are un-marked automatically. A purge is journaled too, so restores know the blob is gone.")
                                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.teal.opacity(0.10)))
                        }
                        Divider().overlay(Theme.hairline)
                        Button {
                            Task { await engine.garbageCollectNow() }
                        } label: {
                            HStack {
                                Image(systemName: "trash.slash")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Clean up now").font(Theme.rounded(16, weight: .medium))
                                    Text("One-off garbage collection: free the blobs of deleted photos that are past the grace period, even with automatic purging off. Blobs are deleted first, then the purge is journaled — a crash in between just retries safely on the next cleanup.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(engine.isConfigured ? Theme.teal : Theme.textTertiary)
                        }
                        .disabled(!engine.isConfigured || engine.phase.isActive)
                        if let status = engine.gcStatus {
                            Text(status)
                                .font(Theme.mono(12))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(status.hasPrefix("✓") ? .green
                                                 : status.hasPrefix("✗") ? .red : Theme.textSecondary)
                        }
                    }

                    knobGroup("Repository") {
                        Text("Every change is committed to an append-only encrypted journal in the bucket — the journal, not this phone, is the source of truth. Checkpoints compact the history into a fresh snapshot; old generations stay untouched (append-only friendly).")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        Divider().overlay(Theme.hairline)
                        Button {
                            Task {
                                compacting = true
                                await engine.compactNow()
                                compacting = false
                            }
                        } label: {
                            HStack {
                                if compacting {
                                    ProgressView().tint(Theme.teal)
                                } else {
                                    Image(systemName: "archivebox")
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(compacting ? "Writing checkpoint…" : "Write checkpoint now")
                                        .font(Theme.rounded(16, weight: .medium))
                                    Text("Commit pending changes and start a fresh generation (a full snapshot). Restores get faster; nothing is deleted.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(engine.isConfigured ? Theme.teal : Theme.textTertiary)
                        }
                        .disabled(!engine.isConfigured || engine.phase.isActive || compacting)
                        if let status = engine.checkpointStatus {
                            Text(status)
                                .font(Theme.mono(12))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(status.hasPrefix("✓") ? .green
                                                 : status.hasPrefix("✗") ? .red : Theme.textSecondary)
                        }
                        Divider().overlay(Theme.hairline)
                        Button { showReloadConfirm = true } label: {
                            HStack {
                                if reloadingIndex {
                                    ProgressView().tint(Theme.teal)
                                } else {
                                    Image(systemName: "arrow.triangle.2.circlepath.doc.on.clipboard")
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(reloadingIndex ? "Reloading…" : "Reload index from repository")
                                        .font(Theme.rounded(16, weight: .medium))
                                    Text("Rebuild the local cache from the bucket's newest checkpoint + journals (chain-verified). Use after a reinstall or if the cache is suspect. Requires this phone's key.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(engine.isConfigured ? Theme.teal : Theme.textTertiary)
                        }
                        .disabled(!engine.isConfigured || engine.phase.isActive || reloadingIndex)
                        .alert("Replace the local index?", isPresented: $showReloadConfirm) {
                            Button("Reload from repository", role: .destructive) {
                                Task {
                                    reloadingIndex = true
                                    await engine.restoreIndexFromRepo()
                                    reloadingIndex = false
                                }
                            }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("The local cache is replaced by what the repository says. Nothing in the bucket changes. Photos on this phone that were never journaled will re-queue on the next scan.")
                        }
                        if let status = engine.attachStatus {
                            Text(status)
                                .font(Theme.mono(12))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .foregroundStyle(status.hasPrefix("✓") ? .green
                                                 : status.hasPrefix("✗") ? .red : Theme.textSecondary)
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
                                    Text("Egress-free: lists the bucket's blobs and checks every backed-up item exists with the expected size. Anything missing or wrong-sized is re-queued.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(engine.isConfigured ? Theme.teal : Theme.textTertiary)
                        }
                        .disabled(!engine.isConfigured || engine.phase.isActive || engine.verifying)
                        if let status = engine.verifyStatus {
                            Text(status)
                                .font(Theme.mono(12))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
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
                            .multilineTextAlignment(.leading)
                            .foregroundStyle(engine.isConfigured ? Theme.teal : Theme.textTertiary)
                        }
                        .disabled(!engine.isConfigured)
                    }

                    knobGroup("Automation") {
                        if premium.isUnlocked {
                            ToggleRow(title: "Back up in the background",
                                      subtitle: "iOS grants short windows (usually overnight, charging, on Wi-Fi) to upload new photos while the app is closed. Best-effort by design.",
                                      isOn: $engine.settings.backgroundBackup)
                        } else {
                            premiumUpsell
                        }
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
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Auto back up on open",
                                  subtitle: "Start a backup when the app opens, if the last run finished more than 30 minutes ago.",
                                  isOn: $engine.settings.autoStartOnLaunch)
                        Divider().overlay(Theme.hairline)
                        Text("Scans are incremental (only what's newer than the last scan) and self-healing: if the library ever holds more items than the index knows about — an old import, an iCloud backfill — the next scan automatically re-checks everything.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        if let status = engine.scanStatus, engine.phase != .scanning {
                            Text(status)
                                .font(Theme.mono(12))
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
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

                    Text(Self.versionFooter)
                        .font(Theme.mono(10)).foregroundStyle(Theme.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 8)
                }
                .padding(16)
                .containerRelativeFrame(.horizontal)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationBarHidden(true)
            .alert("Restore script", isPresented: $showRestoreScriptWarning) {
                Button("Cancel", role: .cancel) {}
                Button("Without secrets") {
                    Task {
                        if let script = await engine.buildRestoreScript(includeSecrets: false) {
                            restoreScript = ScriptDocument(text: script)
                        }
                    }
                }
                Button("With secrets baked in") {
                    Task {
                        // Face ID / passcode prompt happens inside buildRestoreScript.
                        if let script = await engine.buildRestoreScript(includeSecrets: true) {
                            restoreScript = ScriptDocument(text: script)
                        }
                    }
                }
            } message: {
                Text("A single Python file that rebuilds your whole archive on a laptop.\n\n“With secrets baked in” includes your bucket secret key\(keyManager.hasIdentity ? " AND this phone's age secret" : "") in plaintext — one file that just works; store it like a password (Face ID required).\n\n“Without secrets” embeds only the bucket settings; the script shows them at launch and prompts for the two secrets — safe to keep anywhere you'd keep the bucket name.")
            }
            .sheet(item: $restoreScript) { doc in
                RestoreScriptViewer(script: doc.text)
            }
    }

    /// "SnapSiphon v0.2.1 (202607221530 · abc1234) · …" — version/build/hash are
    /// injected by scripts/release.sh; dev builds show v0.0.0 (1 · dev).
    /// Premium unlock row shown in place of the background-backup toggle.
    private var premiumUpsell: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "lock.fill").foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Back up in the background").font(Theme.rounded(16, weight: .medium))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Uploads new photos overnight while the app is closed — a one-time \(premium.displayPrice) upgrade. Everything else is free forever.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task {
                        await premium.purchase()
                        if premium.isUnlocked { engine.scheduleBackgroundBackup() }
                    }
                } label: {
                    HStack(spacing: 6) {
                        if premium.purchasing { ProgressView().tint(.black) }
                        Text(premium.purchasing ? "Purchasing…" : "Unlock · \(premium.displayPrice)")
                            .font(Theme.rounded(14, weight: .semibold))
                    }
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .foregroundStyle(.black)
                    .background(Capsule().fill(Theme.teal))
                }
                .disabled(premium.purchasing)
                Button {
                    Task { await premium.restore() }
                } label: {
                    Text("Restore").font(Theme.rounded(14, weight: .medium)).foregroundStyle(Theme.teal)
                }
            }
            if let err = premium.lastError {
                Text(err).font(Theme.mono(11)).foregroundStyle(.red)
            }
        }
    }

    static let versionFooter: String = {
        let info = Bundle.main
        let v = info.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let b = info.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let h = info.object(forInfoDictionaryKey: "SnapSiphonGitCommit") as? String ?? ""
        return "SnapSiphon v\(v) (\(b)\(h.isEmpty ? "" : " · \(h)")) · age + S3 · your keys, your bucket"
    }()

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
                         subtitle: engine.s3Config.isComplete ? "\(engine.s3Config.bucket) @ \(engine.s3Config.endpoint)" : "Not set",
                         ok: engine.s3Config.isComplete && S3CredentialStore.hasCredentials)
            }
        }
    }

    private func setupRow(icon: String, title: String, subtitle: String, ok: Bool) -> some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.system(size: 18)).foregroundStyle(Theme.teal)
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
