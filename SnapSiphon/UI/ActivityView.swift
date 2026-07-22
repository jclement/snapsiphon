import SwiftUI

struct ActivityView: View {
    @EnvironmentObject var engine: BackupEngine

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    SectionHeader(caption: "Live feed", title: "Activity")

                    Card {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                metric("\(Format.count(engine.sessionUploaded))", "this session")
                                Spacer()
                                metric(Format.bytes(engine.sessionBytes), "encrypted")
                                Spacer()
                                metric(Format.bytesPerSecond(engine.bytesPerSecond), "throughput")
                            }
                        }
                    }

                    if engine.log.isEmpty {
                        emptyState
                    } else {
                        logList
                    }
                }
                .padding(16)
                .containerRelativeFrame(.horizontal)
            }
            .background(Theme.canvas.ignoresSafeArea())
            .navigationBarHidden(true)
        }
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.rounded(18, weight: .bold)).foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.6).lineLimit(1)
            Text(label.uppercased()).font(Theme.mono(9)).tracking(1).foregroundStyle(Theme.textSecondary)
        }
    }

    private var emptyState: some View {
        Card(padding: 28) {
            VStack(spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 34)).foregroundStyle(Theme.textTertiary)
                Text("No activity yet").font(Theme.rounded(17, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Text("Runs and errors will show up here as they happen.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textTertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var logList: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(engine.log) { entry in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(entry.kind))
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(color(entry.kind))
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.message)
                                .font(.system(size: 13)).foregroundStyle(Theme.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(entry.date, style: .time)
                                .font(Theme.mono(10)).foregroundStyle(Theme.textTertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 8)
                    if entry.id != engine.log.last?.id {
                        Divider().overlay(Theme.hairline)
                    }
                }
            }
        }
    }

    private func icon(_ kind: BackupEngine.LogEntry.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(_ kind: BackupEngine.LogEntry.Kind) -> Color {
        switch kind {
        case .info: return Theme.teal
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
