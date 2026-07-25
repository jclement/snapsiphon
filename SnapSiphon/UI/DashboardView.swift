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
            // A repository already exists at the configured folder and this
            // install has no position in it — the user must choose how to
            // attach before anything is written.
            .sheet(item: $engine.pendingAttach) { info in
                AttachRepositorySheet(info: info)
                    .environmentObject(engine)
            }
            // The configured folder is EMPTY but the index still lists uploads
            // from a previous destination — never write a checkpoint that
            // claims backups this bucket doesn't hold.
            .alert("New folder, existing index",
                   isPresented: Binding(get: { engine.pendingFreshInit != nil },
                                        set: { if !$0 { engine.pendingFreshInit = nil } }),
                   presenting: engine.pendingFreshInit) { info in
                Button("Re-upload here") {
                    engine.confirmFreshInitRequeueAll()
                    engine.backUpNow()
                }
                Button("Cancel", role: .cancel) { engine.pendingFreshInit = nil }
            } message: { info in
                Text("This folder is empty, but the index lists \(Format.count(info.staleUploads)) backups made to a previous destination. Re-upload queues them all for THIS folder (already-present files are skipped automatically). Or cancel and fix the destination in Settings → Storage.")
            }
        }
    }

    // MARK: Fixed header

    private var header: some View {
        HStack(alignment: .center) {
            HStack(spacing: 9) {
                Image(systemName: "camera.aperture")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.teal)
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
                case .preparing: Pill(text: "CHECKING", color: .cyan, filled: true)
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
                segments: MediaBackupRing.build(engine.storedSegments),
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

    // Legend for the ring. Idle: a vertical, column-aligned table — one row
    // per kind, colors matching the donut wedges. While lanes are on screen,
    // it collapses to a compact single line to leave room for the streams.
    private var mediaLegend: some View {
        Group {
            if isRunning || engine.uploadLanes.contains(where: { $0 != nil }) {
                compactLegend
            } else {
                verticalLegend
            }
        }
        .frame(maxWidth: .infinity)
    }

    private struct LegendRow: Identifiable {
        let kind: MediaKind
        let count: Int
        let total: Int?     // library denominator where known
        let bytes: Int64
        var id: String { kind.id }
    }

    private var legendRows: [LegendRow] {
        let s = engine.storedSegments
        let hiddenIncluded = engine.settings.includeHidden
        var rows: [LegendRow] = [
            LegendRow(kind: .photo, count: s.photoCount,
                      total: max(0, engine.libraryPhotos - (hiddenIncluded ? engine.libraryHiddenPhotos : 0)),
                      bytes: s.photoBytes),
            LegendRow(kind: .hiddenPhoto, count: s.hiddenPhotoCount,
                      total: engine.libraryHiddenPhotos, bytes: s.hiddenPhotoBytes),
            LegendRow(kind: .clip, count: s.clipCount, total: nil, bytes: s.clipBytes),
            LegendRow(kind: .video, count: s.videoCount,
                      total: max(0, engine.libraryVideos - (hiddenIncluded ? engine.libraryHiddenVideos : 0)),
                      bytes: s.videoBytes),
            LegendRow(kind: .hiddenVideo, count: s.hiddenVideoCount,
                      total: engine.libraryHiddenVideos, bytes: s.hiddenVideoBytes),
        ]
        // Photos/Videos always show; the rest only when they have something
        // stored or something to do.
        rows = rows.filter { $0.kind == .photo || $0.kind == .video || $0.count > 0 || ($0.total ?? 0) > 0 }
        // Hidden rows with the toggle off would show 0/N forever — drop them
        // unless something is actually stored (the caption covers exclusion).
        if !hiddenIncluded {
            rows.removeAll { ($0.kind == .hiddenPhoto || $0.kind == .hiddenVideo) && $0.count == 0 }
        }
        return rows
    }

    private var verticalLegend: some View {
        VStack(spacing: 4) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                ForEach(legendRows) { row in
                    GridRow {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2).fill(row.kind.color)
                                .frame(width: 9, height: 9)
                            Text(row.kind.label)
                                .font(Theme.rounded(13, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                        }
                        .gridColumnAlignment(.leading)
                        Text(row.total.map { "\(Format.count(row.count))/\(Format.count($0))" }
                             ?? Format.count(row.count))
                            .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                            .gridColumnAlignment(.trailing)
                        Text(Format.bytes(row.bytes))
                            .font(Theme.mono(11)).foregroundStyle(Theme.textTertiary)
                            .gridColumnAlignment(.trailing)
                    }
                }
            }
            // Hidden album is never invisible: when it's excluded, say so.
            if engine.hiddenItemCount > 0 && !engine.settings.includeHidden {
                Text("\(Format.count(engine.hiddenItemCount)) hidden excluded (Settings → Hidden album)")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.textTertiary)
            }
        }
    }

    /// Mid-run strip: REMAINING counts per kind — the number that matters
    /// while lanes are chewing through the queue.
    private var compactLegend: some View {
        let s = engine.storedSegments
        let remaining: [(MediaKind, Int)] = [
            (.photo, s.remainingPhotos), (.hiddenPhoto, s.remainingHiddenPhotos),
            (.clip, s.remainingClips), (.video, s.remainingVideos),
            (.hiddenVideo, s.remainingHiddenVideos),
        ].filter { $0.1 > 0 }
        return HStack(spacing: 10) {
            Text(remaining.isEmpty ? "finishing" : "left")
                .font(Theme.mono(10)).foregroundStyle(Theme.textTertiary)
            ForEach(remaining, id: \.0) { kind, count in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(kind.color)
                        .frame(width: 8, height: 8)
                    Text(Format.count(count))
                        .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
        }
    }

    // MARK: Middle section — status panel + live gauges

    @ViewBuilder private func middleSection(now: Date) -> some View {
        VStack(spacing: 8) {
            if let conflict = engine.repoConflict {
                infoPanel(icon: "exclamationmark.octagon.fill", color: .red, spinning: false,
                          title: "Repository conflict — backups halted", subtitle: conflict)
                gaugeRow(now: now)
            } else if engine.phase == .scanning {
                infoPanel(icon: "magnifyingglass", color: .cyan, spinning: true,
                          title: "Scanning library",
                          subtitle: engine.activityDetail ?? "\(Format.count(engine.scanChecked)) checked")
                gaugeRow(now: now)
            } else if engine.phase == .preparing {
                infoPanel(icon: "externaldrive.badge.checkmark", color: .cyan, spinning: true,
                          title: "Checking repository",
                          subtitle: engine.activityDetail ?? "Comparing with the bucket…")
                gaugeRow(now: now)
            } else if let reason = engine.waitingReason {
                infoPanel(icon: "pause.circle.fill", color: .orange, spinning: true,
                          title: "Waiting", subtitle: reason)
                gaugeRow(now: now)
            } else if isRunning || engine.uploadLanes.contains(where: { $0 != nil }) {
                uploadStreams
                gaugeRow(now: now)
            } else if case .failed(let reason) = engine.phase {
                infoPanel(icon: "wifi.exclamationmark", color: .red, spinning: false,
                          title: "Backup stopped", subtitle: reason)
                gaugeRow(now: now)
            } else if engine.counts.failed > 0 {
                infoPanel(icon: "exclamationmark.triangle.fill", color: .red, spinning: false,
                          title: "\(Format.count(engine.counts.failed)) failed to upload",
                          subtitle: "See the Activity tab for details, then Back Up Now to retry.")
                gaugeRow(now: now)
            } else if engine.toBackupPhotos + engine.toBackupVideos > 0 {
                // Counts library-vs-uploaded, so brand-new photos show here
                // immediately at launch — before any scan has indexed them.
                backupReadyBanner
                gaugeRow(now: now)
            } else {
                infoPanel(icon: "checkmark.seal.fill", color: .green, spinning: false,
                          title: idleTitle, subtitle: idleSubtitle)
                gaugeRow(now: now)
            }
        }
    }

    private var backupReadyBanner: some View {
        Button { engine.backUpNow() } label: {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20, weight: .semibold)).foregroundStyle(.black)
                VStack(alignment: .leading, spacing: 2) {
                    Text(readyLine)
                        .font(Theme.rounded(15, weight: .bold)).foregroundStyle(.black)
                        .lineLimit(1).minimumScaleFactor(0.7)
                    Text("Tap to back them up now")
                        .font(.system(size: 12)).foregroundStyle(.black.opacity(0.65))
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 24)).foregroundStyle(.black.opacity(0.8))
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.orange))
        }
    }

    private var readyLine: String {
        var parts: [String] = []
        if engine.toBackupPhotos > 0 {
            parts.append("\(Format.count(engine.toBackupPhotos)) photo\(engine.toBackupPhotos == 1 ? "" : "s")")
        }
        if engine.toBackupVideos > 0 {
            parts.append("\(Format.count(engine.toBackupVideos)) video\(engine.toBackupVideos == 1 ? "" : "s")")
        }
        return parts.joined(separator: " · ") + " to back up"
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
                              progress: slot.progress, kind: slot.kind, phase: slot.phase)
                } else {
                    UploadRow(filename: "idle", byteSize: 0, progress: 0, kind: .photo)
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
                // Live jetsam-relevant footprint — flat means the pipeline streams.
                GaugePill(systemImage: "memorychip",
                          value: String(format: "%.0f MB", MemoryFootprint.currentMB),
                          caption: "memory", accent: .green)
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
                    GaugePill(systemImage: "tray.and.arrow.up",
                              value: Format.count(engine.counts.pending), caption: "queued", accent: Theme.violet)
                    GaugePill(systemImage: "exclamationmark.triangle",
                              value: Format.count(engine.counts.failed), caption: "failed",
                              accent: engine.counts.failed > 0 ? .red : .green)
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
                PrimaryButton(title: "Resume", systemImage: "play.fill") { engine.resume() }
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
                .font(.system(size: 54)).foregroundStyle(Theme.teal)
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
                Image(systemName: icon).font(.system(size: 18)).foregroundStyle(Theme.teal).frame(width: 28)
                Text(title).font(Theme.rounded(16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Image(systemName: ok ? "checkmark.circle.fill" : "circle.dashed")
                    .foregroundStyle(ok ? .green : Theme.textTertiary)
                Image(systemName: "chevron.right").font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
            }
        }
    }
}
