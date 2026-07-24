import SwiftUI

/// A compact stat tile: big number, small label, optional icon + accent.
struct StatTile: View {
    let value: String
    let label: String
    var systemImage: String? = nil
    var accent: Color = Theme.teal

    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 6) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(accent)
                }
                Text(value)
                    .font(Theme.rounded(24, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text(label.uppercased())
                    .font(Theme.mono(10, weight: .medium))
                    .tracking(1)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// A compact gauge: icon + big value + small caption, in a pill. Used in rows
/// on the dashboard to nerd out on live metrics.
struct GaugePill: View {
    let systemImage: String
    let value: String
    let caption: String
    var accent: Color = Theme.teal

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(accent)
            Text(value)
                .font(Theme.mono(15, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
                .minimumScaleFactor(0.5).lineLimit(1)
            Text(caption.uppercased())
                .font(Theme.mono(8, weight: .medium)).tracking(0.8)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 11)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// The five kinds of stored content, with ONE color definition shared by the
/// donut segments, the legend, and the upload lanes — they can never drift.
enum MediaKind: String, CaseIterable, Identifiable {
    case photo, hiddenPhoto, clip, video, hiddenVideo
    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: return "Photos"
        case .hiddenPhoto: return "Hidden photos"
        case .clip: return "Live clips"
        case .video: return "Videos"
        case .hiddenVideo: return "Hidden videos"
        }
    }

    var color: Color {
        switch self {
        case .photo: return Theme.teal
        case .hiddenPhoto: return Theme.teal.opacity(0.38)
        case .clip: return Color.cyan.opacity(0.85)
        case .video: return Theme.violet
        case .hiddenVideo: return Theme.violet.opacity(0.38)
        }
    }

    var isVideo: Bool { self == .video || self == .hiddenVideo || self == .clip }

    static func of(record: AssetRecord) -> MediaKind {
        if AssetRecord.isLiveMotion(record.localIdentifier) { return .clip }
        switch record.mediaType {
        case .video: return record.hidden ? .hiddenVideo : .video
        default: return record.hidden ? .hiddenPhoto : .photo
        }
    }
}

/// The dashboard hero. Two concentric layers:
/// - **Outer ring:** overall file-count progress (uploaded / total files).
/// - **Inner donut:** stored bytes segmented by kind — photos, Live Photo
///   clips, videos, with fainter shades for their Hidden-album portions.
///   Squared (butt-capped) segment ends with thin gaps, pie-instrument style.
/// Centre shows the overall backed-up percentage.
struct MediaBackupRing: View {
    /// One donut wedge. Fainter colors = hidden portions.
    struct Segment: Identifiable {
        let kind: MediaKind
        let bytes: Int64
        let count: Int
        var id: String { kind.id }
        var label: String { kind.label }
        var color: Color { kind.color }
    }

    let fileProgress: Double     // 0…1, outer ring
    let segments: [Segment]
    let centerTitle: String

    var outerWidth: CGFloat = 12
    var innerWidth: CGFloat = 20

    /// Canonical segments shared with the dashboard legend.
    static func build(_ s: BackupIndex.StoredSegments) -> [Segment] {
        [
            Segment(kind: .photo, bytes: s.photoBytes, count: s.photoCount),
            Segment(kind: .hiddenPhoto, bytes: s.hiddenPhotoBytes, count: s.hiddenPhotoCount),
            Segment(kind: .clip, bytes: s.clipBytes, count: s.clipCount),
            Segment(kind: .video, bytes: s.videoBytes, count: s.videoCount),
            Segment(kind: .hiddenVideo, bytes: s.hiddenVideoBytes, count: s.hiddenVideoCount),
        ].filter { $0.bytes > 0 || $0.count > 0 }
    }

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            let rOuter = (side - outerWidth) / 2
            let rInner = rOuter - outerWidth / 2 - 11 - innerWidth / 2
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            ZStack {
                Canvas { ctx, _ in
                    drawInner(ctx, center: center, radius: rInner)
                    drawOuter(ctx, center: center, radius: rOuter)
                }
                VStack(spacing: 1) {
                    Text(centerTitle)
                        .font(Theme.rounded(42, weight: .bold))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                    Text("BACKED UP")
                        .font(Theme.mono(10, weight: .medium)).tracking(1.5)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private let top = -Double.pi / 2

    /// Inner donut: squared-off segments sized by stored bytes per kind, with
    /// a thin gap between neighbours. Hidden portions render fainter.
    private func drawInner(_ ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        let live = segments.filter { $0.bytes > 0 }
        let total = live.reduce(Int64(0)) { $0 + $1.bytes }
        guard total > 0 else {
            arc(ctx, center, radius, from: top, to: top + 2 * .pi, .color(Theme.surfaceHi), innerWidth, cap: .butt)
            return
        }
        let gap = live.count > 1 ? 0.045 : 0.0
        let available = 2 * .pi - gap * Double(live.count)
        var cursor = top
        for segment in live {
            let sweep = available * Double(segment.bytes) / Double(total)
            arc(ctx, center, radius, from: cursor, to: cursor + sweep,
                .color(segment.color), innerWidth, cap: .butt)
            cursor += sweep + gap
        }
    }

    /// Outer ring: file-count progress over a faint track.
    private func drawOuter(_ ctx: GraphicsContext, center: CGPoint, radius: CGFloat) {
        arc(ctx, center, radius, from: top, to: top + 2 * .pi, .color(Theme.surfaceHi), outerWidth)
        let p = max(0, min(fileProgress, 1))
        guard p > 0 else { return }
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(colors: [Theme.teal, Theme.violet]),
            startPoint: CGPoint(x: center.x - radius, y: center.y - radius),
            endPoint: CGPoint(x: center.x + radius, y: center.y + radius))
        arc(ctx, center, radius, from: top, to: top + 2 * .pi * p, shading, outerWidth)
    }

    private func arc(_ ctx: GraphicsContext, _ center: CGPoint, _ radius: CGFloat,
                     from: Double, to: Double, _ shading: GraphicsContext.Shading, _ width: CGFloat,
                     cap: CGLineCap = .round) {
        var path = Path()
        path.addArc(center: center, radius: radius,
                    startAngle: .radians(from), endAngle: .radians(to), clockwise: false)
        ctx.stroke(path, with: shading, style: StrokeStyle(lineWidth: width, lineCap: cap))
    }
}

/// A dense one-line upload row: phase icon, filename (left), size (right), with
/// the row background itself filling left-to-right as the upload progresses.
/// The leading glyph tells you what the lane is doing right now — pulling from
/// iCloud, encrypting, or on the wire.
struct UploadRow: View {
    let filename: String
    let byteSize: Int64
    let progress: Double
    let kind: MediaKind          // lane color = donut segment color
    var phase: AssetProcessor.Phase = .uploading

    private var phaseIcon: (name: String, color: Color) {
        switch phase {
        case .exporting: return ("icloud.and.arrow.down", .cyan)
        case .encrypting: return ("lock.fill", .orange)
        case .uploading:
            let name = kind == .clip ? "livephoto.play" : (kind.isVideo ? "video.fill" : "photo.fill")
            return (name, kind.color)
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(kind.color.opacity(0.30))
                    .frame(width: max(6, geo.size.width * max(0, min(progress, 1))))
                    .animation(.linear(duration: 0.25), value: progress)
            }
            HStack(spacing: 8) {
                Image(systemName: phaseIcon.name)
                    .font(.system(size: 11))
                    .foregroundStyle(phaseIcon.color)
                    .frame(width: 15)
                    .contentTransition(.symbolEffect(.replace))
                Text(filename)
                    .font(Theme.mono(12)).foregroundStyle(Theme.textPrimary)
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 6)
                Text(byteSize > 0 ? Format.bytes(byteSize) : "—")
                    .font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
            }
            .padding(.horizontal, 11)
        }
        .frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Theme.surfaceHi))
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(Theme.hairline, lineWidth: 1))
    }
}

/// A circular progress ring with a centred label — the dashboard hero.
struct ProgressRing: View {
    let progress: Double        // 0…1
    let centerTitle: String
    let centerSubtitle: String

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.surfaceHi, lineWidth: 16)
            Circle()
                .trim(from: 0, to: max(0.001, min(progress, 1)))
                .stroke(Theme.brandGradient,
                        style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.5), value: progress)
            VStack(spacing: 2) {
                Text(centerTitle)
                    .font(Theme.rounded(40, weight: .bold))
                    .foregroundStyle(Theme.textPrimary)
                    .contentTransition(.numericText())
                Text(centerSubtitle.uppercased())
                    .font(Theme.mono(11, weight: .medium))
                    .tracking(1.5)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

/// A labelled slider row used across settings.
struct SliderRow: View {
    let title: String
    let subtitle: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 1
    let valueLabel: (Double) -> String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.rounded(16, weight: .medium)).foregroundStyle(Theme.textPrimary)
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Text(valueLabel(value))
                    .font(Theme.mono(14, weight: .semibold))
                    .foregroundStyle(Theme.teal)
            }
            Slider(value: $value, in: range, step: step)
                .tint(Theme.teal)
        }
    }
}

/// A toggle row with title + explanation.
struct ToggleRow: View {
    let title: String
    let subtitle: String
    @Binding var isOn: Bool
    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.rounded(16, weight: .medium)).foregroundStyle(Theme.textPrimary)
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
            }
        }
        .tint(Theme.teal)
    }
}

/// A pill badge (status chips).
struct Pill: View {
    let text: String
    var color: Color = Theme.teal
    var filled: Bool = false
    var body: some View {
        Text(text)
            .font(Theme.mono(11, weight: .semibold))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .foregroundStyle(filled ? .black : color)
            .background(
                Capsule().fill(filled ? AnyShapeStyle(color) : AnyShapeStyle(color.opacity(0.15))))
    }
}

/// A labelled text field styled for the app.
struct FieldRow: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var mono: Bool = false
    var secure: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(Theme.mono(10, weight: .medium)).tracking(1)
                .foregroundStyle(Theme.textSecondary)
            Group {
                if secure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(mono ? Theme.mono(14) : .system(size: 15))
            .foregroundStyle(Theme.textPrimary)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceHi))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
        }
    }
}
