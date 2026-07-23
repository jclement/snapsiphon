# SnapSiphon Help

## Who

SnapSiphon is made by **Straybits Corp** — [straybits.ca](https://straybits.ca).

Source is on [GitHub](https://github.com/jclement/snapsiphon) under the MIT license.

## Encryption

Every photo and video is encrypted **on this device** with [age](https://age-encryption.org) (X25519 key agreement + ChaCha20-Poly1305 in 64 KiB authenticated STREAM chunks), implemented on Apple CryptoKit. Files are encrypted to *all* of your configured recipients at once — a software key, this phone's key, a Secure Enclave (`age1se1…`) or YubiKey (`age1yubikey1…`) — and any one matching secret can decrypt.

Your storage provider only ever sees ciphertext. Output is byte-compatible with the reference `age` tool.

## How your backups are stored

Inside your bucket, under your chosen prefix, lives a **repository**:

- **Blobs** → `objects/<name>` — every photo/video, encrypted, under a *salted content address*: an HMAC of the file's hash keyed with a secret per-repository salt (stored inside the encrypted checkpoint). Deterministic, so identical files share one blob and interrupted uploads resume for free — but without the salt the name reveals nothing, and no outsider can hash a known photo to probe whether you have it. No extensions either.
- **Checkpoints** → `checkpoints/000001/checkpoint.age` — an encrypted SQLite snapshot of the whole index, starting a *generation*. Each generation is restorable on its own.
- **Journals** → `checkpoints/000001/journal000001.age`, … — append-only encrypted change logs (adds, deletions, purges). Every journal records the hash of its predecessor, so rollback, deletion, or reordering of history is detectable.
- **The bucket is the source of truth** — the app's local database is just a cache and can be rebuilt from the repository at any time (Settings → Repository).
- Blobs upload **before** their journal entry commits: a crash mid-backup strands at most an unreferenced blob, never a phantom journal entry.
- **Deletions** are journaled immediately; blobs are physically removed only if "Purge deleted backups" is on, after the grace period (and Object Lock permitting).
- **Integrity**: the repository stores sha256 hashes of both the original file and the ciphertext; restores verify end-to-end. Uploads also carry Content-MD5.
- **Live Photos**: the full-quality still is backed up; the 3-second motion clip is not yet (planned).

## Getting your photos back

Three independent paths, none of which need this app:

1. **Restore script** (Settings → Disaster recovery): one Python file with credentials + key baked in. `python3 restore.py` reads the newest checkpoint, replays the journals (verifying the chain), and rebuilds everything with original filenames and integrity checks. Needs the `age` CLI *or* `pip3 install cryptography`.
2. **age CLI** anywhere: `age -d -i key.txt file.age` — even the checkpoint is just an age file holding a SQLite database.
3. This app on a new phone: import your secret key, point at the bucket, and the attach prompt reloads the whole index from the repository — no re-uploading.

## Setting up storage

Any S3-compatible provider works — Backblaze B2, Cloudflare R2, AWS, Wasabi, MinIO, or fully self-hosted with [picos3](https://github.com/jclement/picos3) over Tailscale (compose file in the repo's docs/). The Storage screen has a per-provider cheat sheet for endpoints and regions. What makes a *great* bucket:

- **Append-only key** — SnapSiphon only needs read/write/list (delete is only used by the optional "Purge deleted backups"). A key that can't delete means malware or a stolen phone can't destroy the archive.
- **Object Lock / retention** (B2) — makes objects immutable until the lock expires. Tamper-proof, even with delete rights.
- **Keep all versions, no lifecycle expiry** — this is a forever archive; nothing should age out on its own.
- **One bucket, one key** — scope the application key to just this bucket.

## Credits

- [age encryption](https://age-encryption.org) — format by Filippo Valsorda (C2SP spec).
- Apple CryptoKit, PhotoKit, SwiftUI, BackgroundTasks.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (build tooling).

No third-party code is bundled in the app — the crypto, S3 client, and storage layer are implemented directly on Apple frameworks so every byte is auditable in the repo.
