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
                    Inside your bucket, under your chosen prefix, lives a **repository**:

                    • **Blobs** → `objects/<random-uuid>` — every photo/video, encrypted, under a purely random name. No content hashes, no extensions: the bucket learns nothing about what's in it, and identical files can't even be correlated.
                    • **Checkpoints** → `checkpoints/000001/checkpoint.age` — an encrypted SQLite snapshot of the whole index, starting a *generation*. Each generation is restorable on its own.
                    • **Journals** → `checkpoints/000001/journal000001.age`, … — append-only encrypted change logs (adds, deletions, purges). Every journal records the hash of its predecessor, so rollback, deletion, or reordering of history is detectable.
                    • **The bucket is the source of truth** — the app's local database is just a cache and can be rebuilt from the repository at any time (Settings → Repository).
                    • Blobs upload **before** their journal entry commits: a crash mid-backup strands at most an unreferenced blob, never a phantom journal entry.
                    • **Deletions** are journaled immediately; blobs are physically removed only if "Purge deleted backups" is on, after the grace period (and Object Lock permitting).
                    • **Integrity**: the repository stores sha256 hashes of both the original file and the ciphertext; restores verify end-to-end. Uploads also carry Content-MD5.
                    • **Live Photos**: the full-quality still is backed up; the 3-second motion clip is not yet (planned).
                    """)
                }

                card("Getting your photos back") {
                    Text("""
                    Three independent paths, none of which need this app:

                    1. **Restore script** (Settings → Disaster recovery): one Python file with credentials + key baked in. `python3 restore.py` reads the newest checkpoint, replays the journals (verifying the chain), and rebuilds everything with original filenames and integrity checks. Needs the `age` CLI *or* `pip3 install cryptography`.
                    2. **age CLI** anywhere: `age -d -i key.txt file.age` — even the checkpoint is just an age file holding a SQLite database.
                    3. This app on a new phone: import your secret key, point at the bucket, and the attach prompt reloads the whole index from the repository — no re-uploading.
                    """)
                }

                card("Setting up storage") {
                    Text("""
                    Any S3-compatible provider works — Backblaze B2, Cloudflare R2, AWS, Wasabi, MinIO, or fully self-hosted with [picos3](https://github.com/jclement/picos3) over Tailscale (compose file in the repo's docs/). The Storage screen has a per-provider cheat sheet for endpoints and regions. What makes a *great* bucket:

                    • **Append-only key** — SnapSiphon only needs read/write/list (delete is only used by the optional "Purge deleted backups"). A key that can't delete means malware or a stolen phone can't destroy the archive.
                    • **Object Lock / retention** (B2) — makes objects immutable until the lock expires. Tamper-proof, even with delete rights.
                    • **Keep all versions, no lifecycle expiry** — this is a forever archive; nothing should age out on its own.
                    • **One bucket, one key** — scope the application key to just this bucket.
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
