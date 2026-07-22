import SwiftUI

/// Shared visual language: SnapSiphon is "polished and nerdy" — deep charcoal
/// canvas, a teal→violet signature gradient, and monospaced type for the parts
/// that should feel like a terminal (keys, hashes, throughput).
enum Theme {
    static let teal = Color("BrandTeal")
    static let violet = Color("BrandViolet")

    static let canvas = Color(red: 0.043, green: 0.055, blue: 0.078)
    static let surface = Color(red: 0.086, green: 0.098, blue: 0.129)
    static let surfaceHi = Color(red: 0.125, green: 0.141, blue: 0.180)
    static let hairline = Color.white.opacity(0.07)
    static let textPrimary = Color.white.opacity(0.95)
    static let textSecondary = Color.white.opacity(0.55)
    static let textTertiary = Color.white.opacity(0.35)

    static let brandGradient = LinearGradient(
        colors: [teal, violet],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    static let subtleGradient = LinearGradient(
        colors: [surfaceHi, surface],
        startPoint: .top, endPoint: .bottom)

    static func mono(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    static func rounded(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}

// MARK: - Reusable surfaces

/// A rounded "card" panel used throughout the app.
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Theme.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Theme.hairline, lineWidth: 1))
            )
    }
}

/// Section header with a small caption above bold rounded title.
struct SectionHeader: View {
    let caption: String
    let title: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(caption.uppercased())
                .font(Theme.mono(11, weight: .medium))
                .tracking(1.5)
                .foregroundStyle(Theme.teal)
            Text(title)
                .font(Theme.rounded(22, weight: .bold))
                .foregroundStyle(Theme.textPrimary)
        }
    }
}

/// A big gradient call-to-action button.
struct PrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(Theme.rounded(17, weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .foregroundStyle(.black)
            .background(Theme.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .opacity(enabled ? 1 : 0.35)
        }
        .disabled(!enabled)
    }
}

/// A secondary (outlined) button.
struct GhostButton: View {
    let title: String
    var systemImage: String? = nil
    var tint: Color = Theme.textPrimary
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title).font(Theme.rounded(16, weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .foregroundStyle(tint)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
                    .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Theme.surfaceHi)))
        }
    }
}

// MARK: - Formatting helpers

enum Format {
    static func bytes(_ count: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false   // "0 KB", not "Zero KB"
        return f.string(fromByteCount: count)
    }
    static func bytesPerSecond(_ bps: Double) -> String {
        guard bps > 1 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(bps), countStyle: .file) + "/s"
    }
    static func count(_ n: Int) -> String {
        NumberFormatter.localizedString(from: NSNumber(value: n), number: .decimal)
    }
    static func percent(_ ratio: Double) -> String {
        String(format: "%.1f%%", ratio * 100)
    }

    /// Compact duration: "45s", "12m", "1h 4m".
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m" }
        let h = s / 3600, m = (s % 3600) / 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }

    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    static func relative(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        if now.timeIntervalSince(date) < 5 { return "just now" }
        return relativeFormatter.localizedString(for: date, relativeTo: now)
    }
}
