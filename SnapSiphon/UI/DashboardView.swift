import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var engine: BackupEngine

    /// Overall file-count progress: uploaded files ÷ library files. Prefers the
    /// live library totals; falls back to the index if they're not loaded yet.
    private var overallProgress: Double {
        let done = engine.uploadedPhotos + engine.uploadedVideos
        let libTotal = engine.libraryPhotos + engine.libraryVideos
        if libTotal > 0 { return min(1, Double(done) / Double(libTotal)) }
        guard engine.counts.total > 0 else { return 0 }
        return Double(engine.counts.uploaded) / Double(engine.counts.total)
    }
    private var isBusy: Bool { engine.phase.isActive }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 10)

                if engine.isConfigured {
                    configuredBody
                } else {
                    notConfiguredBody
                }
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationBarHidden(true)
            .task { engine.refreshCounts(); await engine.refreshLibraryCounts() }
        }
    }

    // MARK: Fixed header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.brandGradient)
                VStack(alignment: .leading, spacing: 1) {
                    Text("SnapSiphon")
                        .font(Theme.rounded(22, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Encrypted photo backup")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            statusPill
        }
    }

    private var statusPill: some View {
        Group {
            if engine.waitingReason != nil {
                Pill(text: "WAITING", color: .orange, filled: true)
            } else {
                switch engine.phase {
                case .idle: Pill(text: "READY", color: Theme.teal)
                case .scanning: Pill(text: "SCANNING", color: .cyan, filled: true)
                case .running: Pill(text: "UPLOADING", color: Theme.teal, filled: true)
                case .paused: Pill(text: "PAUSED", color: .orange)
                case .finished: Pill(text: "DONE", color: .green, filled: true)
                case .failed: Pill(text: "ERROR", color: .red, filled: true)
                }
            }
        }
    }

    // MARK: Configured — fills the screen, no scrolling

    private var configuredBody: some View {
        VStack(spacing: 12) {
            // The ring eats the remaining vertical space so it stays the hero.
            MediaBackupRing(
                fileProgress: overallProgress,
                photoBytes: engine.storedPhotoBytes,
                videoBytes: engine.storedVideoBytes,
                centerTitle: ringTitle)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, 4)

            mediaLegend

            // Live-ticking so speed / ETA / "last backup" stay current each second.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                middleSection(now: context.date)
            }

            controls
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // Legend for the ring: inner donut = stored bytes split photos/videos.
    private var mediaLegend: some View {
        HStack(spacing: 18) {
            legendItem(color: Theme.teal, label: "Photos",
                       count: engine.uploadedPhotos, total: engine.libraryPhotos,
                       bytes: engine.storedPhotoBytes)
            legendItem(color: Theme.violet, label: "Videos",
                       count: engine.uploadedVideos, total: engine.libraryVideos,
                       bytes: engine.storedVideoBytes)
        }
        .frame(maxWidth: .infinity)
    }

    private func legendItem(color: Color, label: String, count: Int, total: Int, bytes: Int64) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(label).font(Theme.rounded(13, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(total > 0 ? "\(Format.count(count))/\(Format.count(total))" : Format.count(count))
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                }
                Text(Format.bytes(bytes)).font(Theme.mono(10)).foregroundStyle(Theme.textTertiary)
            }
        }
    }

    // MARK: Middle section — status panel + live gauges

    @ViewBuilder private func middleSection(now: Date) -> some View {
        VStack(spacing: 8) {
            if engine.phase == .scanning {
                infoPanel(icon: "magnifyingglass", color: .cyan, spinning: true,
                          title: "Scanning library",
                          subtitle: "\(Format.count(engine.scanChecked)) checked")
                gaugeRow(now: now)
            } else if let reason = engine.waitingReason {
                infoPanel(icon: "pause.circle.fill", color: .orange, spinning: true,
                          title: "Waiting", subtitle: reason)
                gaugeRow(now: now)
            } else if isRunning || engine.uploadLanes.contains(where: { $0 != nil }) {
                uploadStreams
                gaugeRow(now: now)
            } else if engine.counts.failed > 0 {
                infoPanel(icon: "exclamationmark.triangle.fill", color: .red, spinning: false,
                          title: "\(Format.count(engine.counts.failed)) failed to upload",
                          subtitle: "See the Activity tab for details, then Back Up Now to retry.")
                gaugeRow(now: now)
            } else {
                infoPanel(icon: engine.counts.pending > 0 ? "tray.full.fill" : "checkmark.seal.fill",
                          color: engine.counts.pending > 0 ? .orange : .green, spinning: false,
                          title: idleTitle, subtitle: idleSubtitle)
                gaugeRow(now: now)
            }
        }
    }

    // Dense per-thread upload rows — a FIXED number of lanes (one per parallel
    // thread) so rows never appear/disappear between files; an idle lane just
    // shows a faded placeholder until its next file starts.
    private var uploadStreams: some View {
        let lanes = engine.uploadLanes.isEmpty ? [UploadSlot?.none] : engine.uploadLanes
        return VStack(spacing: 5) {
            HStack {
                Text("\(lanes.count) UPLOAD LANE\(lanes.count == 1 ? "" : "S")")
                    .font(Theme.mono(9, weight: .medium)).tracking(1.5).foregroundStyle(Theme.teal)
                Spacer()
                Text("\(Format.count(engine.sessionUploaded)) done · \(Format.bytes(engine.sessionBytes))")
                    .font(Theme.mono(9)).foregroundStyle(Theme.textTertiary)
            }
            .padding(.horizontal, 2)
            ForEach(Array(lanes.enumerated()), id: \.offset) { _, slot in
                if let slot {
                    UploadRow(filename: slot.filename, byteSize: slot.byteSize,
                              progress: slot.progress, isVideo: slot.isVideo)
                } else {
                    UploadRow(filename: "idle", byteSize: 0, progress: 0, isVideo: false)
                        .opacity(0.35)
                }
            }
        }
    }

    private typealias UploadSlot = BackupEngine.UploadSlot

    private var isRunning: Bool { engine.phase == .running }

    @ViewBuilder private func gaugeRow(now: Date) -> some View {
        if isRunning {
            HStack(spacing: 8) {
                GaugePill(systemImage: "gauge.with.dots.needle.67percent",
                          value: Format.bytesPerSecond(engine.bytesPerSecond), caption: "speed")
                GaugePill(systemImage: "clock.badge.checkmark",
                          value: Format.duration(engine.estimatedSecondsRemaining(now: now) ?? .nan),
                          caption: "eta", accent: Theme.violet)
                GaugePill(systemImage: "square.and.arrow.up",
                          value: "\(Format.count(engine.sessionUploaded))", caption: "this run", accent: .green)
            }
        } else {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    GaugePill(systemImage: "clock.arrow.circlepath",
                              value: Format.relative(engine.lastBackupDate, now: now), caption: "last backup")
                    GaugePill(systemImage: "doc",
                              value: Format.bytes(engine.averageObjectBytes), caption: "avg size", accent: Theme.violet)
                    GaugePill(systemImage: "tray.full",
                              value: Format.bytes(engine.averageObjectBytes * Int64(engine.counts.pending)),
                              caption: "est. left", accent: .orange)
                }
                HStack(spacing: 8) {
                    GaugePill(systemImage: "photo.stack",
                              value: Format.count(engine.counts.total), caption: "in library")
                    GaugePill(systemImage: "cube.transparent",
                              value: Format.percent(engine.bloomFillRatio), caption: "bloom fill", accent: Theme.violet)
                    GaugePill(systemImage: "scope",
                              value: Format.percent(engine.bloomFalsePositiveRate), caption: "false-pos", accent: .green)
                }
            }
        }
    }

    private func infoPanel(icon: String, color: Color, spinning: Bool,
                           title: String, subtitle: String) -> some View {
        Card(padding: 13) {
            HStack(spacing: 12) {
                if spinning {
                    ProgressView().tint(color)
                } else {
                    Image(systemName: icon).font(.system(size: 18)).foregroundStyle(color)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.rounded(15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private var ringTitle: String {
        let libTotal = engine.libraryPhotos + engine.libraryVideos
        guard libTotal > 0 || engine.counts.total > 0 else { return "0%" }
        return "\(Int((overallProgress * 100).rounded()))%"
    }

    private var idleTitle: String {
        if engine.counts.total == 0 { return "Ready to back up" }
        return engine.counts.pending > 0 ? "\(Format.count(engine.counts.pending)) waiting" : "Everything backed up"
    }
    private var idleSubtitle: String {
        if engine.counts.total == 0 { return "Tap Back Up Now to scan your library and begin." }
        return engine.counts.pending > 0
            ? "Tap Back Up Now to encrypt and upload them."
            : "Tap Back Up Now to check for anything new."
    }

    // MARK: Controls

    @ViewBuilder private var controls: some View {
        if engine.phase == .running {
            PrimaryButton(title: "Pause", systemImage: "pause.fill") { engine.pause() }
        } else if engine.phase == .scanning {
            PrimaryButton(title: "Scanning…", systemImage: "hourglass", enabled: false) {}
        } else if engine.phase == .paused {
            VStack(spacing: 10) {
                PrimaryButton(title: "Resume", systemImage: "play.fill") { engine.start() }
            }
        } else {
            PrimaryButton(title: "Back Up Now", systemImage: "arrow.up.circle.fill", enabled: !isBusy) {
                engine.backUpNow()
            }
        }
    }

    // MARK: Not configured

    private var notConfiguredBody: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 54)).foregroundStyle(Theme.brandGradient)
            VStack(spacing: 6) {
                Text("Let's get set up").font(Theme.rounded(22, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text("SnapSiphon needs an encryption key and an S3-compatible bucket before it can protect your photos.")
                    .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 8)

            VStack(spacing: 10) {
                NavigationLink { KeysView() } label: {
                    setupRow("key.fill", "Encryption key", engine.keyManager.isConfigured)
                }
                NavigationLink { StorageSetupView() } label: {
                    setupRow("externaldrive.connected.to.line.below.fill", "Storage bucket",
                             engine.s3Config.isComplete && S3CredentialStore.hasCredentials)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 16)
    }

    private func setupRow(_ icon: String, _ title: String, _ ok: Bool) -> some View {
        Card {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.brandGradient).frame(width: 28)
                Text(title).font(Theme.rounded(16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ok ? .green : Theme.textTertiary)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
