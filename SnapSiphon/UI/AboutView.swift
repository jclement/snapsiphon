import SwiftUI

/// About & Help: who made it, how the data is stored (so a future you — or
/// anyone you hand the bucket to — can reconstruct everything without the app),
/// what crypto is in play, and credits.
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                // All help content lives in Resources/Help.md — one `## `
                // section per card. Edit the markdown, not this view.
                ForEach(HelpDoc.sections(), id: \.title) { section in
                    card(section.title) {
                        MarkdownBlocks(markdown: section.body)
                    }
                }

                Text(SettingsView.versionFooter)
                    .font(Theme.mono(10)).foregroundStyle(Theme.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 4)
            }
            .padding(16)
            .containerRelativeFrame(.horizontal)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationBarHidden(true)   // it's a tab now — the custom header carries it
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "camera.aperture")
                .font(.system(size: 40, weight: .bold))
                .foregroundStyle(Theme.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("SnapSiphon").font(Theme.rounded(24, weight: .bold)).foregroundStyle(Theme.textPrimary)
                Text("Encrypted photo backup — your keys, your bucket")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.vertical, 6)
    }

    private func card(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased()).font(Theme.mono(11, weight: .medium)).tracking(1.5)
                .foregroundStyle(Theme.teal)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    content()
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.textSecondary)
                        .tint(Theme.teal)
                }
            }
        }
    }
}
