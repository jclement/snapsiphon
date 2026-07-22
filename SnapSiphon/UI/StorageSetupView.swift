import SwiftUI

struct StorageSetupView: View {
    @EnvironmentObject var engine: BackupEngine

    @State private var accessKeyID = ""
    @State private var secretKey = ""
    @State private var testing = false
    @State private var testResult: TestResult?
    @State private var applyingLifecycle = false
    @State private var lifecycleMessage: String?

    enum TestResult { case ok, fail(String) }

    private let retentionOptions: [Int] = [0, 30, 90, 180, 365, 730]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(caption: "S3-compatible", title: "Storage")

                providerPicker

                Card {
                    VStack(alignment: .leading, spacing: 14) {
                        FieldRow(label: "Endpoint host", placeholder: endpointPlaceholder,
                                 text: $engine.s3Config.endpoint, mono: true)
                        FieldRow(label: "Region", placeholder: engine.s3Config.provider.defaultRegion,
                                 text: $engine.s3Config.region, mono: true)
                        FieldRow(label: "Bucket", placeholder: "my-photos", text: $engine.s3Config.bucket, mono: true)
                        FieldRow(label: "Key prefix (folder)", placeholder: "SnapSiphon",
                                 text: $engine.s3Config.prefix, mono: true)
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

                retentionCard

                if let result = testResult {
                    testBanner(result)
                }

                VStack(spacing: 12) {
                    PrimaryButton(title: "Save", systemImage: "checkmark",
                                  enabled: engine.s3Config.isComplete) {
                        persistCredentials()
                    }
                    GhostButton(title: testing ? "Testing…" : "Save & test connection",
                                systemImage: "antenna.radiowaves.left.and.right", tint: Theme.teal) {
                        persistCredentials()
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
                    engine.s3Config.provider = provider
                    if engine.s3Config.region.isEmpty { engine.s3Config.region = provider.defaultRegion }
                } label: {
                    Text(provider.title)
                        .font(Theme.rounded(13, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 12)
                        .foregroundStyle(engine.s3Config.provider == provider ? .black : Theme.textSecondary)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(engine.s3Config.provider == provider ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.surfaceHi)))
                }
            }
        }
    }

    private var endpointPlaceholder: String {
        switch engine.s3Config.provider {
        case .backblazeB2: return "s3.us-west-004.backblazeb2.com"
        case .cloudflareR2: return "<account>.r2.cloudflarestorage.com"
        case .custom: return "s3.example.com"
        }
    }

    private var retentionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.violet)
                    Text("Server-side retention").font(Theme.rounded(16, weight: .semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
                Text("Push a bucket lifecycle rule so the provider auto-deletes old objects — enforced even if this app is gone. Best-effort: honoured by R2 and AWS; partial on B2.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(retentionOptions, id: \.self) { days in
                            let selected = engine.settings.lifecycleExpirationDays == days
                            Button {
                                engine.settings.lifecycleExpirationDays = days
                            } label: {
                                Text(days == 0 ? "Keep forever" : "\(days) days")
                                    .font(Theme.rounded(14, weight: .semibold))
                                    .fixedSize()
                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                    .foregroundStyle(selected ? .black : Theme.textSecondary)
                                    .background(
                                        Capsule().fill(selected
                                                       ? AnyShapeStyle(Theme.brandGradient)
                                                       : AnyShapeStyle(Theme.surfaceHi)))
                            }
                        }
                    }
                    .padding(.vertical, 2)
                }

                GhostButton(title: applyingLifecycle ? "Applying…" : "Apply to bucket",
                            systemImage: "arrow.up.doc", tint: Theme.violet) {
                    Task {
                        applyingLifecycle = true
                        lifecycleMessage = nil
                        let result = await engine.applyLifecyclePolicy()
                        applyingLifecycle = false
                        switch result {
                        case .success: lifecycleMessage = "Applied."
                        case .failure(let e): lifecycleMessage = e.localizedDescription
                        }
                    }
                }
                if let msg = lifecycleMessage {
                    Text(msg).font(Theme.mono(11)).foregroundStyle(Theme.textSecondary)
                }
            }
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
        if engine.s3Config.region.isEmpty {
            engine.s3Config.region = engine.s3Config.provider.defaultRegion
        }
        if let creds = S3CredentialStore.load() {
            accessKeyID = creds.accessKeyID
            secretKey = creds.secretAccessKey
        }
    }

    private func persistCredentials() {
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
