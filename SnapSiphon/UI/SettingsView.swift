import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var engine: BackupEngine

    var body: some View {
        NavigationStack {
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
                                  subtitle: "How many files travel at once.",
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
                        ToggleRow(title: "Mirror deletions",
                                  subtitle: "When you delete a photo on-device, tombstone it in the manifest on the next scan (and purge the object if the bucket allows).",
                                  isOn: $engine.settings.propagateDeletes)
                        if engine.settings.propagateDeletes {
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .foregroundStyle(.orange).font(.system(size: 13))
                                Text("This turns your backup into a mirror. Deletes are recorded in the encrypted manifest so a restore skips them. On Object-Lock buckets the bytes can't be removed early — they expire via your retention rule.")
                                    .font(.system(size: 12)).foregroundStyle(.orange)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                        }
                    }

                    knobGroup("Restore manifest") {
                        ToggleRow(title: "Keep encrypted manifest",
                                  subtitle: "Store an age-encrypted key→filename map in the bucket so a bucket-only restore can rename everything back.",
                                  isOn: $engine.settings.keepBucketManifest)
                        Divider().overlay(Theme.hairline)
                        Button {
                            Task { _ = await engine.writeManifest() }
                        } label: {
                            HStack {
                                Image(systemName: "doc.badge.arrow.up")
                                Text("Write manifest now").font(Theme.rounded(16, weight: .medium))
                                Spacer()
                            }
                            .foregroundStyle(engine.isConfigured ? Theme.teal : Theme.textTertiary)
                        }
                        .disabled(!engine.isConfigured || engine.phase.isActive)
                    }

                    knobGroup("Scanning") {
                        ToggleRow(title: "Fast scan",
                                  subtitle: "Only check photos newer than the last scan. Much faster on big libraries.",
                                  isOn: $engine.settings.incrementalScan)
                        Divider().overlay(Theme.hairline)
                        Button {
                            Task { await engine.deepScan() }
                        } label: {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath")
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Deep scan").font(Theme.rounded(16, weight: .medium))
                                    Text("Re-check the entire library, ignoring the fast-scan mark. Use after importing older photos.")
                                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                                }
                                Spacer()
                            }
                            .foregroundStyle(Theme.teal)
                        }
                        .disabled(engine.phase.isActive)
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
        }
    }

    private var keySubtitle: String {
        let n = engine.keyManager.recipients.count
        return n == 0 ? "Not set" : "\(n) recipient\(n == 1 ? "" : "s")"
    }

    private var setupLinks: some View {
        VStack(spacing: 12) {
            NavigationLink { KeysView() } label: {
                setupRow(icon: "key.fill",
                         title: "Encryption key",
                         subtitle: keySubtitle,
                         ok: engine.keyManager.isConfigured)
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
