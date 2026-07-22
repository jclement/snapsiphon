import SwiftUI

struct StorageSetupView: View {
    @EnvironmentObject var engine: BackupEngine

    /// Edits happen on a local draft, committed only by Save. The config used
    /// to bind straight to engine.s3Config, which persisted on every keystroke —
    /// meaning the destination could be silently redirected without ever
    /// pressing Save. Nothing sticks until an explicit, gated commit now.
    @State private var draft = S3Config()
    @State private var loaded = false
    @State private var accessKeyID = ""
    @State private var secretKey = ""
    @State private var testing = false
    @State private var testResult: TestResult?

    enum TestResult { case ok, fail(String) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(caption: "S3-compatible", title: "Storage")

                providerPicker

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        FieldRow(label: "Endpoint host", placeholder: endpointPlaceholder,
                                 text: $draft.endpoint, mono: true)
                        FieldRow(label: "Region", placeholder: draft.provider.defaultRegion,
                                 text: $draft.region, mono: true)
                        FieldRow(label: "Bucket", placeholder: "my-photos", text: $draft.bucket, mono: true)
                        FieldRow(label: "Key prefix (folder)", placeholder: "SnapSiphon",
                                 text: $draft.prefix, mono: true)
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

                if let result = testResult {
                    testBanner(result)
                }

                VStack(spacing: 12) {
                    PrimaryButton(title: "Save", systemImage: "checkmark",
                                  enabled: draft.isComplete) {
                        commit()
                    }
                    GhostButton(title: testing ? "Testing…" : "Save & test connection",
                                systemImage: "antenna.radiowaves.left.and.right", tint: Theme.teal) {
                        commit()
                        Task { await runTest() }
                    }
                }
            }
            .padding(16)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Storage")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: prefillCredentials)
    }

    private var providerPicker: some View {
        HStack(spacing: 10) {
            ForEach(S3Config.Provider.allCases) { provider in
                Button {
                    draft.provider = provider
                    if draft.region.isEmpty { draft.region = provider.defaultRegion }
                } label: {
                    Text(provider.title)
                        .font(Theme.rounded(13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(draft.provider == provider ? .black : Theme.textSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(draft.provider == provider ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.surfaceHi)))
                }
            }
        }
    }

    private var endpointPlaceholder: String {
        switch draft.provider {
        case .backblazeB2: return "s3.us-west-004.backblazeb2.com"
        case .cloudflareR2: return "<account>.r2.cloudflarestorage.com"
        case .custom: return "s3.example.com"
        }
    }

    private func testBanner(_ result: TestResult) -> some View {
        Card {
            switch result {
            case .ok:
                Label("Connected — bucket reachable and credentials valid.", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13)).foregroundStyle(.green)
            case .fail(let message):
                VStack(alignment: .leading, spacing: 4) {
                    Label("Connection failed", systemImage: "xmark.octagon.fill")
                        .font(Theme.rounded(14, weight: .semibold)).foregroundStyle(.red)
                    Text(message).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                }
            }
        }
    }

    private func prefillCredentials() {
        guard !loaded else { return }
        loaded = true
        draft = engine.s3Config
        if draft.region.isEmpty { draft.region = draft.provider.defaultRegion }
        if let creds = S3CredentialStore.load() {
            accessKeyID = creds.accessKeyID
            secretKey = creds.secretAccessKey
        }
    }

    /// Commit the draft: config becomes live, credentials go to the Keychain.
    private func commit() {
        engine.s3Config = draft
        if !accessKeyID.isEmpty && !secretKey.isEmpty {
            engine.saveCredentials(accessKeyID: accessKeyID, secret: secretKey)
        }
    }

    private func runTest() async {
        testing = true
        testResult = nil
        let result = await engine.testConnection()
        testing = false
        switch result {
        case .success: testResult = .ok
        case .failure(let error): testResult = .fail(error.localizedDescription)
        }
    }
}
