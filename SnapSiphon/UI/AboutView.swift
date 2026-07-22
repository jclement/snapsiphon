import SwiftUI

/// About & Help: who made it, how the data is stored (so a future you — or
/// anyone you hand the bucket to — can reconstruct everything without the app),
/// what crypto is in play, and credits.
struct AboutView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                card("Who") {
                    Text("SnapSiphon is made by **Straybits Corp**.")
                    Link(destination: URL(string: "https://straybits.ca")!) {
                        Label("straybits.ca", systemImage: "globe")
                            .font(Theme.rounded(14, weight: .medium)).foregroundStyle(Theme.teal)
                    }
                    Link(destination: URL(string: "https://github.com/jclement/snapsiphon")!) {
                        Label("Source on GitHub (MIT)", systemImage: "chevron.left.forwardslash.chevron.right")
                            .font(Theme.rounded(14, weight: .medium)).foregroundStyle(Theme.teal)
                    }
                }

                card("Encryption") {
                    Text("Every photo and video is encrypted **on this device** with [age](https://age-encryption.org) (X25519 key agreement + ChaCha20-Poly1305 in 64 KiB authenticated STREAM chunks), implemented on Apple CryptoKit. Files are encrypted to *all* of your configured recipients at once — a software key, this phone's key, a Secure Enclave (`age1se1…`) or YubiKey (`age1yubikey1…`) — and any one matching secret can decrypt. Your storage provider only ever sees ciphertext. Output is byte-compatible with the reference `age` tool.")
                }

                card("How your backups are stored") {
                    Text("""
                    Inside your bucket, under your chosen prefix:

                    • **Photos/videos** → `ab/<sha256-of-asset-id>.<ext>.age` — hashed names (the extension is kept so you can tell types apart), or `yyyy/MM/<name>.age` if filename encryption is off.
                    • **Manifests** → `manifests/manifest-<timestamp>.age` — an age-encrypted JSON index written after every backup: object key → original filename, dates, sizes, and which items were deleted on-device. The newest one is the source of truth.
                    • **Deletions** are marked in the manifest immediately; blobs are only physically removed if "Purge deleted backups" is on, after the grace period.
                    • **Integrity**: every upload carries its MD5 (Content-MD5); Verify compares stored checksums against bucket ETags with zero downloads.
                    """)
                }

                card("Getting your photos back") {
                    Text("""
                    Three independent paths, none of which need this app:

                    1. **Restore script** (Settings → Disaster recovery): one Python file with credentials + key baked in. `python3 restore.py` rebuilds everything with original filenames. Needs the `age` CLI *or* `pip3 install cryptography`.
                    2. **age CLI** anywhere: `age -d -i key.txt file.age`.
                    3. This app on a new phone: import your secret key, point at the bucket, and *Adopt existing backups* re-indexes without re-uploading.
                    """)
                }

                card("Credits") {
                    Text("""
                    • [age encryption](https://age-encryption.org) — format by Filippo Valsorda (C2SP spec).
                    • Apple CryptoKit, PhotoKit, SwiftUI, BackgroundTasks.
                    • [XcodeGen](https://github.com/yonaskolb/XcodeGen) (build tooling).

                    No third-party code is bundled in the app — the crypto, S3 client, and storage layer are implemented directly on Apple frameworks so every byte is auditable in the repo.
                    """)
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
                .foregroundStyle(Theme.brandGradient)
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
