import SwiftUI

/// Raised when Back Up Now finds an existing SnapSiphon repository in the
/// configured bucket/folder that this install has never attached to. Writing
/// into someone else's journal chain is the one unrecoverable mistake the
/// format allows, so nothing proceeds until the user picks a path.
struct AttachRepositorySheet: View {
    @EnvironmentObject var engine: BackupEngine
    @Environment(\.dismiss) private var dismiss
    let info: BackupEngine.ExistingRepoInfo

    @State private var working = false
    @State private var report: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.badge.questionmark")
                            .font(.system(size: 34)).foregroundStyle(Theme.teal)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Existing backup found")
                                .font(Theme.rounded(20, weight: .bold)).foregroundStyle(Theme.textPrimary)
                            Text("\(info.generations) generation\(info.generations == 1 ? "" : "s") · \(info.journalFiles) journal\(info.journalFiles == 1 ? "" : "s") in this folder")
                                .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                        }
                    }

                    Text("This folder already contains a SnapSiphon repository — probably from another phone, or from this one before a reinstall. Nothing has been uploaded.")
                        .font(.system(size: 14)).foregroundStyle(Theme.textSecondary)

                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "exclamationmark.octagon.fill")
                            .foregroundStyle(.red).font(.system(size: 14))
                        Text("Two devices must NEVER back up into the same folder. Each writes its own journal chain; interleaving them corrupts both backups. If another phone is still using this folder, give this one a different folder.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.red.opacity(0.12)))

                    if !engine.keyManager.hasIdentity {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: "key.slash")
                                .foregroundStyle(.orange).font(.system(size: 14))
                            Text("This phone holds no secret key, so it cannot read this repository. To take over or verify, first import your saved AGE-SECRET-KEY in Settings → Encryption key. With a public key only, your option here is a different folder.")
                                .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.orange.opacity(0.12)))
                    }

                    VStack(spacing: 10) {
                        optionButton(icon: "arrow.triangle.2.circlepath",
                                     title: "Take over this repository",
                                     detail: "The other device is retired (or this is a reinstall): reload its index from the bucket, then continue backing up here. Requires this phone's key.",
                                     color: Theme.teal) {
                            Task {
                                working = true
                                let ok = await engine.restoreIndexFromRepo()
                                report = engine.attachStatus
                                working = false
                                if ok { dismiss() }
                            }
                        }
                        optionButton(icon: "doc.text.magnifyingglass",
                                     title: "Verify match first",
                                     detail: "Read the repository's index (touching nothing) and compare it with this phone: matching items, differences, and whether every backed-up file is actually present.",
                                     color: Theme.violet) {
                            Task {
                                working = true
                                await engine.compareWithRepo()
                                report = engine.attachStatus
                                working = false
                            }
                        }
                        optionButton(icon: "folder.badge.plus",
                                     title: "Use a different folder",
                                     detail: "Keep this repository untouched. Change the folder (prefix) in Settings → Storage, then Back Up Now starts a fresh repository there.",
                                     color: .orange) {
                            dismiss()
                        }
                        optionButton(icon: "xmark.circle",
                                     title: "Not now",
                                     detail: "Do nothing. Backups stay paused until you decide.",
                                     color: Theme.textTertiary) {
                            dismiss()
                        }
                    }

                    if working { ProgressView().tint(Theme.teal).frame(maxWidth: .infinity) }
                    if let report {
                        reportBanner(report)
                    }
                }
                .padding(16)
            }
            .containerRelativeFrame(.horizontal)
            .background(Theme.canvas.ignoresSafeArea())
            .interactiveDismissDisabled(working)
        }
    }

    /// The verify/take-over outcome, styled so success is unmissable: a green
    /// (or red/orange) banner with a big status icon, headline first line, and
    /// the details below.
    private func reportBanner(_ report: String) -> some View {
        let good = report.hasPrefix("✓")
        let bad = report.hasPrefix("✗")
        let color: Color = good ? .green : bad ? .red : .orange
        let icon = good ? "checkmark.seal.fill" : bad ? "xmark.octagon.fill" : "exclamationmark.triangle.fill"
        let lines = report.split(separator: "\n", maxSplits: 1)
        let headline = String(lines.first ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "✓✗⚠ "))
        let detail = lines.count > 1 ? String(lines[1]) : nil
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 26))
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 4) {
                Text(headline)
                    .font(Theme.rounded(17, weight: .bold))
                    .foregroundStyle(color)
                if let detail {
                    Text(detail)
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textPrimary.opacity(0.85))
                }
            }
            Spacer(minLength: 0)
        }
        .multilineTextAlignment(.leading)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(color.opacity(0.14)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.5), lineWidth: 1))
    }

    private func optionButton(icon: String, title: String, detail: String,
                              color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(Theme.rounded(16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                    Text(detail).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surface))
        }
        .buttonStyle(.plain)
        .disabled(working)
    }
}
