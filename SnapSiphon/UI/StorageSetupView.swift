import SwiftUI

struct StorageSetupView: View {
    @EnvironmentObject var engine: BackupEngine

    /// Edits happen on a local draft, committed only by Save & Test (or the
    /// explicit save-anyway path). Nothing persists mid-edit.
    @State private var draft = S3Config()
    @State private var loaded = false
    @State private var accessKeyID = ""
    @State private var secretKey = ""
    @State private var testing = false
    @State private var status: Status?
    @State private var askSaveAnyway: String?   // holds the failure message

    enum Status { case saved, savedUntested }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(caption: "Any S3-compatible provider", title: "Storage")

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        FieldRow(label: "Endpoint host", placeholder: "s3.us-west-004.backblazeb2.com",
                                 text: $draft.endpoint, mono: true)
                        FieldRow(label: "Region", placeholder: "us-west-004",
                                 text: $draft.region, mono: true)
                        FieldRow(label: "Bucket", placeholder: "my-photos", text: $draft.bucket, mono: true)
                        FieldRow(label: "Key prefix (folder)", placeholder: "SnapSiphon",
                                 text: $draft.prefix, mono: true)
                        Divider().overlay(Theme.hairline)
                        ToggleRow(title: "Path-style addressing",
                                  subtitle: "Requests go to endpoint/bucket/… instead of bucket.endpoint/…. Needed for MinIO and most self-hosted servers; leave off for B2, AWS, Wasabi. R2 uses on.",
                                  isOn: Binding(get: { draft.usesPathStyle },
                                                set: { draft.pathStyle = $0 }))
                    }
                }

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Credentials").font(Theme.rounded(16, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                        Text("Stored only in your device Keychain — never in a settings file or export.")
                            .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        FieldRow(label: "Access key ID", text: $accessKeyID, mono: true)
                        FieldRow(label: "Secret access key", text: $secretKey, mono: true, secure: true)
                    }
                }

                if let status {
                    statusBanner(status)
                }

                if engine.isRunActive {
                    Text("A backup is running — pause it before changing storage, so journals and blobs can't split across two destinations.")
                        .font(.system(size: 12)).foregroundStyle(.orange)
                }
                PrimaryButton(title: testing ? "Testing…" : "Save & Test",
                              systemImage: testing ? "hourglass" : "checkmark.seal",
                              enabled: draft.isComplete && !accessKeyID.isEmpty && !secretKey.isEmpty
                                       && !testing && !engine.isRunActive) {
                    Task { await saveAndTest() }
                }

                providerCheatSheet
                bucketGuidance
            }
            .padding(16)
            .containerRelativeFrame(.horizontal)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prefill)
        .alert("Connection failed — save anyway?",
               isPresented: Binding(get: { askSaveAnyway != nil },
                                    set: { if !$0 { askSaveAnyway = nil } })) {
            Button("Save anyway") {
                commit()
                status = .savedUntested
                askSaveAnyway = nil
            }
            Button("Keep editing", role: .cancel) { askSaveAnyway = nil }
        } message: {
            Text(askSaveAnyway ?? "")
        }
    }

    // MARK: Save & Test — one button: test the draft first, commit on success

    private func saveAndTest() async {
        testing = true
        status = nil
        defer { testing = false }
        let creds = S3Credentials(accessKeyID: accessKeyID, secretAccessKey: secretKey)
        let client = S3Client(config: draft, credentials: creds)
        do {
            try await client.testConnection()
            commit()
            status = .saved
        } catch {
            // Nothing was saved — offer to save anyway (e.g. setting up offline).
            askSaveAnyway = error.localizedDescription
        }
    }

    private func commit() {
        let old = engine.s3Config
        // ANY change to where objects land is a destination change — prefix
        // and path-style included. A prefix edit moves the whole repository.
        if old.isComplete, (old.bucket != draft.bucket || old.endpoint != draft.endpoint
                            || old.prefix != draft.prefix || old.usesPathStyle != draft.usesPathStyle) {
            engine.noteDestinationChanged()
        }
        engine.s3Config = draft
        if !accessKeyID.isEmpty && !secretKey.isEmpty {
            engine.saveCredentials(accessKeyID: accessKeyID, secret: secretKey)
        }
    }

    private func prefill() {
        guard !loaded else { return }
        loaded = true
        draft = engine.s3Config
        if let creds = S3CredentialStore.load() {
            accessKeyID = creds.accessKeyID
            secretKey = creds.secretAccessKey
        }
    }

    private func statusBanner(_ status: Status) -> some View {
        Card {
            switch status {
            case .saved:
                Label("Saved — bucket reachable and credentials valid.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(.green)
            case .savedUntested:
                Label("Saved without a successful connection test — backups will keep retrying, but double-check the settings.",
                      systemImage: "exclamationmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(.orange)
            }
        }
    }

    // MARK: Provider cheat sheet

    private struct ProviderHint: Identifiable {
        let id: String
        let endpoint: String
        let region: String
        let pathStyle: String
        let note: String
    }

    private static let hints: [ProviderHint] = [
        .init(id: "Backblaze B2", endpoint: "s3.us-west-004.backblazeb2.com",
              region: "us-west-004", pathStyle: "off",
              note: "Endpoint is shown on your bucket's page; the region is the middle of it. Turn on Object Lock when creating the bucket for a tamper-proof archive."),
        .init(id: "Cloudflare R2", endpoint: "<accountid>.r2.cloudflarestorage.com",
              region: "auto", pathStyle: "on",
              note: "Account ID is in the R2 dashboard. Region is literally the word auto."),
        .init(id: "AWS S3", endpoint: "s3.us-east-1.amazonaws.com",
              region: "us-east-1", pathStyle: "off",
              note: "Use the region your bucket lives in, in both fields."),
        .init(id: "Wasabi", endpoint: "s3.us-west-1.wasabisys.com",
              region: "us-west-1", pathStyle: "off",
              note: "Region matches the endpoint."),
        .init(id: "picos3 + Tailscale (self-hosted)", endpoint: "picos3.your-tailnet.ts.net",
              region: "us-east-1", pathStyle: "on",
              note: "A tiny single-bucket S3 server that serves HTTPS with your Tailscale cert — backups stay entirely on your tailnet. Bucket = your PICOS3_BUCKET; keys = the PICOS3_ACCESS/SECRET_KEY env vars. Copy-paste compose file: github.com/jclement/snapsiphon → docs/self-hosting-picos3.md."),
        .init(id: "MinIO / self-hosted", endpoint: "minio.example.com",
              region: "us-east-1", pathStyle: "on",
              note: "Any HTTPS S3-compatible server works (HTTPS is required — the app never speaks plain HTTP). Region is whatever your server expects (often us-east-1)."),
    ]

    private var providerCheatSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("PROVIDER CHEAT SHEET").font(Theme.mono(11, weight: .medium)).tracking(1.5)
                .foregroundStyle(Theme.teal)
            Card {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.hints) { hint in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(hint.id).font(Theme.rounded(14, weight: .semibold))
                                .foregroundStyle(Theme.textPrimary)
                            Text("endpoint \(hint.endpoint) · region \(hint.region) · path-style \(hint.pathStyle)")
                                .font(Theme.mono(11)).foregroundStyle(Theme.teal)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(hint.note).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                        }
                        .padding(.vertical, 8)
                        if hint.id != Self.hints.last?.id {
                            Divider().overlay(Theme.hairline)
                        }
                    }
                }
            }
        }
    }

    // MARK: Bucket guidance

    private var bucketGuidance: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SETTING UP A GOOD BUCKET").font(Theme.mono(11, weight: .medium)).tracking(1.5)
                .foregroundStyle(Theme.teal)
            Card {
                VStack(alignment: .leading, spacing: 10) {
                    guidanceRow("lock.shield.fill", .green,
                                "Append-only is the sweet spot: SnapSiphon never needs delete permission unless you turn on \"Purge deleted backups\". Use an application key with only read/write/list and ransomware or a stolen unlocked phone can't destroy the archive. Deletions are still tracked in the encrypted journal.")
                    guidanceRow("clock.badge.checkmark.fill", .cyan,
                                "Object Lock (B2) / retention makes it tamper-proof even with delete rights — nothing can be removed until the lock expires. Pairs well with the purge grace period.")
                    guidanceRow("arrow.triangle.2.circlepath", Theme.violet,
                                "Keep all versions (B2's default): an accidental overwrite is always recoverable. Skip lifecycle auto-expiry rules — this is a keep-forever archive.")
                    guidanceRow("key.fill", .orange,
                                "Scope the key to one bucket: a dedicated application key that can only touch this bucket, not your whole account.")
                }
            }
        }
    }

    private func guidanceRow(_ icon: String, _ color: Color, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon).font(.system(size: 14)).foregroundStyle(color).frame(width: 20)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
        }
    }
}
