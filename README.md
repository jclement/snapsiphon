# SnapSiphon

Encrypted iPhone photo & video backup to your own S3-compatible storage.
Polished and nerdy. Your keys, your bucket, zero trust in the provider.

<p align="center"><em>age encryption · Backblaze B2 / Cloudflare R2 · SwiftUI</em></p>

## What it does

SnapSiphon walks your photo library, encrypts every original **on-device** with
[age](https://age-encryption.org), and uploads the ciphertext to an
S3-compatible bucket you control. The storage provider never sees a decrypted
byte — or a filename, or even a content hash: blobs are stored under purely
random names, and an encrypted checkpoint + journal repository maps them back.

- **End-to-end encryption with age.** Paste an `age1…` public key you already
  own (SnapSiphon can then *encrypt but never decrypt* — the safest mode), or
  generate a fresh X25519 pair on-device. The implementation is native
  CryptoKit and is **byte-compatible with the reference `age` tool**: you can
  restore anywhere with `age -d -i key.txt photo.age`.
- **Bring your own bucket.** First-class presets for **Backblaze B2** and
  **Cloudflare R2**, plus a custom endpoint. Requests are signed with
  AWS Signature V4; credentials live only in the iOS Keychain.
- **The bucket is the source of truth.** The repository layout is
  `objects/<random-uuid>` for blobs plus `checkpoints/NNNNNN/` generations, each
  holding an encrypted SQLite snapshot (`checkpoint.age`) and append-only
  encrypted journals of every change (adds, deletions, purges). Journals chain
  by ciphertext hash (tamper-evident), blobs upload **before** their journal
  entry commits (a crash strands only an ignorable orphan), and the phone's
  SQLite is just a rebuildable cache. Scans stay fast via a single
  known-identifier query and an oldest-first high-water mark.
- **Safe multi-device story.** Attaching to a folder that already holds a
  repository raises an explicit choice (take over / verify match / new folder),
  and a foreign journal appearing mid-chain halts writes with a loud conflict
  banner — two writers can never silently interleave.
- **Lots of knobs — all enforced.** Photos/videos/favorites filters,
  parallel-upload count, **mid-stream speed limit** (a throttled bound-stream
  body, not just a per-file average), **Wi-Fi-only** and **pause-on-low-battery**
  (the run loop parks on a closed gate and resumes automatically), keep-screen-on,
  and **verify-before-upload** (HEAD-skip objects already in
  the bucket).
- **Multiple recipients, incl. hardware keys.** Encrypts to every recipient at
  once (any one decrypts). Native X25519 (`age1…`) plus **Secure Enclave**
  (`age1se1…`) and **YubiKey** (`age1yubikey1…`) plugin recipients via the
  `piv-p256` stanza — implemented in CryptoKit, so no plugin binary or hardware
  is needed to *encrypt*; only the hardware can decrypt.
- **Forever archive with safe deletes.** No retention/expiry — backups are kept
  indefinitely. Purging is off by default (pure append-only). A photo deleted
  on-device is always **journaled as a tombstone**; its blob is physically freed
  only if purging is on (or via the manual *Clean up now* garbage collection),
  after a **grace period** and once Object Lock retention expires. Photos that
  reappear within the window are **resurrected** — an accidental iCloud wipe
  can't cascade into the bucket.
- **Break-glass restore.** A generated single-file Python script (credentials +
  key baked in) replays the newest checkpoint and journals — verifying the
  chain and each file's sha256 — with no SnapSiphon and no SDKs; even the
  checkpoint is just an age file holding SQLite.
- **Detailed progress & stats.** A live dashboard: dual-ring (file-count
  progress + stored-bytes-by-type), per-stream upload bars, live gauges
  (speed / ETA / last-backup), and a running activity log.

## Architecture

| Area | Files | Notes |
|------|-------|-------|
| Crypto | `Crypto/Age.swift`, `Bech32.swift`, `AgeKeyManager.swift` | Native age v1 (X25519 + ChaCha20-Poly1305 STREAM), Keychain-backed keys |
| Storage | `Storage/SigV4.swift`, `S3Client.swift`, `S3CredentialStore.swift` | SigV4 signing, streaming `URLSession` uploads, `UNSIGNED-PAYLOAD` |
| Repository | `Repo/Repository.swift` | Bucket format: naming, journal model, chain hashing, age-encrypted encode/decode |
| Index | `Index/SQLiteDatabase.swift`, `BackupIndex.swift` | libsqlite3 (WAL), serialized — a cache of the repository |
| Photos | `Photos/PhotoLibrary.swift` | PhotoKit auth + original-resource export |
| Engine | `Engine/BackupEngine.swift`, `AssetProcessor.swift`, `RateLimiter.swift`, `ThroughputMeter.swift` | Orchestration, bounded concurrency, throttling |
| UI | `UI/*`, `App/*` | SwiftUI, dark "polished and nerdy" theme |

## Data flow per asset

```
PhotoKit original ──▶ temp file ──▶ age.Encryptor (streaming) ──▶ *.age temp
                                                                     │
                                              SigV4 PUT ◀────────────┘
                                                   │
                                        BackupIndex (SQLite, WAL)
```

Everything streams through temp files in 64 KiB chunks, so a 4K video never sits
in memory in the clear.

## Building

Requires Xcode 26+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open SnapSiphon.xcodeproj
```

Select a signing team in the target's *Signing & Capabilities* (Photos access
and Keychain work on device; the simulator has no photo originals to export).

## Verifying the crypto

The age output is checked against the real tool. With `age`/`age-keygen`
installed you can reproduce the interop test:

```sh
age-keygen -o key.txt                 # note the printed age1… recipient
# encrypt something with SnapSiphon's Age.swift, then:
age -d -i key.txt photo.age > photo   # decrypts byte-for-byte
```

## Security model

- Photos are encrypted **before** they leave the device. The provider stores
  opaque `*.age` blobs.
- In public-key-only mode SnapSiphon holds **no** decryption key — losing the
  phone cannot expose the archive.
- **If you generate a pair, the secret key is the only thing that can restore
  your photos.** Back it up in a password manager. Lose it and the backups are
  unrecoverable — that's the point.

## Status

v1 — core pipeline implemented; builds for the iOS Simulator SDK. Crypto is
verified against the reference toolchain: age output decrypts byte-for-byte with
`age`; multi-recipient files decrypt with any key; and the `piv-p256` output
decrypts on a real **Secure Enclave** via `age-plugin-se` (YubiKey uses the
identical stanza — the user's exact recipient produces the correct tag). The
speed-limit throttle holds its cap (±3%), and the Content-MD5 matches `openssl`.

The repository format is exercised end-to-end in a harness: a repo built with
the app's own format code (checkpoint snapshot, chained journals, deletes and
purges) restores correctly through the generated Python script — both decrypt
backends, `--all` semantics, integrity hashes, and the tamper-evidence warning.

Natural next steps: multipart uploads for videos over the ~5 GB single-PUT
ceiling (and resumable large uploads), and a pluggable backend protocol so
non-S3 targets (SFTP/Borg/Restic) could slot beside `S3Client`.

## License

MIT — see [LICENSE](LICENSE).
