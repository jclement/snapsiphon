# SnapSiphon Help

## Why

SnapSiphon exists because of a NAS. A shiny new network-storage box arrived, its photo-backup app was switched on with great optimism, and — let's just say the optimism did not survive the week.

Which forced the actual question: photos are the one dataset that's truly irreplaceable, and the two standard answers are both uncomfortable. Trusting everything to a single vendor alone is a single point of failure with a monthly fee. Syncing my private photo collection in plaintext to somebody else's cloud is a hard nope.

So — *SnapSiphon*:

- Always encrypted **phone-side** (age encryption, multiple keys, obfuscated file names — the bucket never learns what anything is).
- Pushed to **S3-compatible storage you control** — Backblaze B2, Cloudflare R2, MinIO, even a self-hosted box over Tailscale.
- **Soft deletes** that respect append-only buckets: nothing is ever silently destroyed.
- A one-tap **verify** that proves every backup is really there.
- **Parallel uploads** with actual knobs.
- An in-app **Python restore script** that just works — your photos come back on any laptop, no SnapSiphon required.
- **Background backups** and a nudge when you haven't backed up in a while.

The rule underneath all of it: your photos should outlive any app, any provider, and any NAS. Including this one.

## Who

SnapSiphon is made by **Straybits Corp** — [straybits.ca](https://straybits.ca).

Source is on [GitHub](https://github.com/jclement/snapsiphon) under the MIT license.

## Encryption

Every photo and video is encrypted **on this device** with [age](https://age-encryption.org) (X25519 key agreement + ChaCha20-Poly1305 in 64 KiB authenticated STREAM chunks), implemented on Apple CryptoKit. Files are encrypted to *all* of your configured recipients at once — a software key, this phone's key, a Secure Enclave (`age1se1…`) or YubiKey (`age1yubikey1…`) — and any one matching secret can decrypt.

Your storage provider only ever sees ciphertext. Output is byte-compatible with the reference `age` tool.

## How your backups are stored

Inside your bucket, under your chosen prefix, lives a **repository**:

- **Blobs** → `objects/ab/<name>` (sharded by the address's first two characters, so filesystem-backed storage and local mirrors never face one giant directory) — every photo/video, encrypted, under a *salted content address*: an HMAC of the file's hash keyed with a secret per-repository salt (stored inside the encrypted checkpoint). Deterministic, so identical files share one blob and interrupted uploads resume for free — but without the salt the name reveals nothing, and no outsider can hash a known photo to probe whether you have it. No extensions either.
- **Checkpoints** → `checkpoints/000001/checkpoint.age` — an encrypted SQLite snapshot of the whole index, starting a *generation*. Each generation is restorable on its own.
- **Journals** → `checkpoints/000001/journal000001.age`, … — append-only encrypted change logs (adds, deletions, purges). Every journal records the hash of its predecessor, so rollback, deletion, or reordering of history is detectable.
- **The bucket is the source of truth** — the app's local database is just a cache and can be rebuilt from the repository at any time (Settings → Repository).
- Blobs upload **before** their journal entry commits: a crash mid-backup strands at most an unreferenced blob, never a phantom journal entry.
- **Deletions** are journaled immediately; blobs are physically removed only by garbage collection — the automatic "Purge deleted backups" toggle or the manual *Clean up now* button — after the grace period (and Object Lock permitting).
- **Integrity**: the repository stores sha256 hashes of both the original file and the ciphertext; restores verify end-to-end. Uploads also carry Content-MD5.
- **Live Photos**: the full-quality still is always backed up; turn on *Live Photo motion clips* (Settings → What to back up) to also store each ~3-second clip as its own encrypted file — enabling it later back-fills clips for everything already backed up.
- **Very large videos**: a single upload tops out around the S3 5 GB single-request ceiling (provider-dependent). Files beyond it fail with a clear error rather than uploading partially; multipart support is planned.

## One phone per folder

- Each device writes its own journal chain, so **two devices must never back up into the same folder** — give each its own prefix (or bucket).
- Pointing a fresh install at a folder that already holds a repository raises a prompt: **take over** (reload the index from the bucket — right after a reinstall or when the old phone is retired), **verify match first** (read-only comparison), or **use a different folder**.
- If a foreign journal ever appears where this phone was about to write, backups halt with a conflict banner instead of corrupting anything.
- After taking over on a **new** phone, the repository's history is preserved and nothing re-uploads (identical content is recognized by its address). The new phone's own library is re-indexed alongside; deletion tracking applies only to photos this phone has actually seen.

## What to back up

- **Photos / Videos / Favorites-only** filters, plus **Back up from** — an optional cutoff date: content captured before it is skipped and left out of the progress ring. Handy for testing, or when older content already lives in another backup.
- **Live Photo motion clips** (optional): store each Live Photo's ~3-second clip as its own encrypted file; enabling it back-fills clips for stills already backed up.
- **Hidden album** (optional, off by default): hidden photos are often the most sensitive, so they're excluded unless you opt in. Either way, *hiding* a photo after it's backed up never deletes its backup — only real deletion starts the tombstone/grace-period process.
- **Photo access**: with *full* access everything works. Under *limited* access (only selected photos shared), backup works but **deletion tracking is disabled** — an unselected photo is indistinguishable from a deleted one, so nothing is ever tombstoned in that mode.
- **Mass-deletion fuse**: if a huge fraction of the archive suddenly reads as deleted (an iCloud hiccup, a signed-out account), SnapSiphon refuses to record the deletions and says so, instead of tombstoning your whole archive.

## Background backups & Premium

- The one paid feature: **Back up in the background** (a small one-time purchase). iOS grants short processing windows — typically overnight, charging, on Wi-Fi — and SnapSiphon uploads new photos during them. Best-effort by design: iOS decides when.
- Everything else — manual backups, verification, restore, all the knobs — is free forever.
- **Reminders**: optional notification when no backup has run for N days; pairs well with background backup as a safety net.

## Face ID lock

Once configured, the Settings tab locks behind Face ID / passcode, so nobody holding your unlocked phone can quietly redirect the bucket, add their own key, or export the restore script. Revealing the secret key and exporting a with-secrets restore script each require a separate confirmation on top.

## Getting your photos back

Three independent paths, none of which need this app:

1. **Restore script** (Settings → Disaster recovery): one Python file. `python3 restore.py` shows its configuration for review (ENTER to confirm, or pick a number to change a value), reads the newest checkpoint, replays the journals (verifying the chain), and rebuilds everything with original filenames and integrity checks. Export it **with secrets baked in** (one file that just works — store it like a password) or **without secrets** (the script prompts for the bucket secret key and age secret at run time — safe to keep anywhere). Needs the `age` CLI *or* `pip3 install cryptography`.
2. **age CLI** anywhere: `age -d -i key.txt file.age` — even the checkpoint is just an age file holding a SQLite database.
3. This app on a new phone: import your secret key, point at the bucket, and the attach prompt reloads the whole index from the repository — no re-uploading.

## Setting up storage

Any S3-compatible provider works — Backblaze B2, Cloudflare R2, AWS, Wasabi, MinIO, or fully self-hosted with [picos3](https://github.com/jclement/picos3) over Tailscale (compose file in the repo's docs/). The Storage screen has a per-provider cheat sheet for endpoints and regions. What makes a *great* bucket:

- **Append-only key** — SnapSiphon only needs read/write/list for backups. Delete permission (specifically *version* delete on versioned buckets) is used only by garbage collection — the "Purge deleted backups" toggle and *Clean up now*. A key that can't delete means malware or a stolen phone can't destroy the archive; cleanup then simply reports "blocked" until retention expires or you use a fuller key.
- **Object Lock / retention** (B2) — makes objects immutable until the lock expires. Tamper-proof, even with delete rights.
- **Keep all versions, no lifecycle expiry** — this is a forever archive; nothing should age out on its own.
- **One bucket, one key** — scope the application key to just this bucket.

## Credits

- [age encryption](https://age-encryption.org) — format by Filippo Valsorda (C2SP spec).
- Apple CryptoKit, PhotoKit, SwiftUI, BackgroundTasks.
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (build tooling).

No third-party code is bundled in the app — the crypto, S3 client, and storage layer are implemented directly on Apple frameworks so every byte is auditable in the repo.
