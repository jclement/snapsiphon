import SwiftUI

struct KeysView: View {
    @EnvironmentObject var engine: BackupEngine
    @Environment(\.dismiss) private var dismiss

    // Observe the key manager directly so the list refreshes the instant a key
    // is added/removed (the view otherwise only observes `engine`).
    @ObservedObject private var manager = AgeKeyManager.shared

    @State private var pastedRecipient = ""
    @State private var generatedSecret: String?
    @State private var showSecret = false
    @State private var errorText: String?
    @State private var pendingRemoval: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                SectionHeader(caption: "age encryption", title: "Your keys")

                explainer

                if !manager.recipients.isEmpty {
                    recipientsCard
                }
                if let secret = generatedSecret {
                    secretRevealCard(secret)
                }

                importCard
                generateCard
            }
            .padding(16)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Encryption")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Key error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Remove this recipient?",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                if let r = pendingRemoval { manager.removeRecipient(r) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            Text("Future backups won't be encrypted to this key. Files already uploaded stay decryptable by whichever keys were set when they were backed up.")
        }
    }

    // MARK: Sections

    private var explainer: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Label("Encrypted on-device, to every key", systemImage: "lock.shield.fill")
                    .font(Theme.rounded(15, weight: .semibold)).foregroundStyle(Theme.textPrimary)
                Text("SnapSiphon encrypts each photo with [age](https://age-encryption.org) to **all** the recipients below — any one of the matching secret keys can restore it. Add a software key, your laptop's key, an offline backup key, or a hardware key: **Secure Enclave** (`age1se1…`) and **YubiKey** (`age1yubikey1…`) recipients work here, and only the hardware can decrypt. Your provider only ever sees ciphertext.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                    .tint(Theme.teal)
            }
        }
    }

    private var recipientsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 0) {
                HStack {
                    Text("RECIPIENTS").font(Theme.mono(10, weight: .medium)).tracking(1)
                        .foregroundStyle(Theme.teal)
                    Spacer()
                    Text("\(manager.recipients.count) key\(manager.recipients.count == 1 ? "" : "s")")
                        .font(Theme.mono(10)).foregroundStyle(Theme.textSecondary)
                }
                .padding(.bottom, 10)

                ForEach(manager.recipients, id: \.self) { recipient in
                    recipientRow(recipient)
                    if recipient != manager.recipients.last {
                        Divider().overlay(Theme.hairline).padding(.vertical, 8)
                    }
                }
            }
        }
    }

    private func recipientKind(_ r: String) -> (label: String, color: Color)? {
        if r.hasPrefix("age1se1") { return ("SECURE ENCLAVE", .cyan) }
        if r.hasPrefix("age1yubikey1") { return ("YUBIKEY", .green) }
        return nil
    }

    private func recipientRow(_ recipient: String) -> some View {
        let isPair = manager.identityRecipient == recipient
        let kind = recipientKind(recipient)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Pill(text: isPair ? "PAIR (on device)" : "PUBLIC-ONLY",
                         color: isPair ? Theme.violet : Theme.teal)
                    if let kind { Pill(text: kind.label, color: kind.color, filled: true) }
                }
                Text(recipient)
                    .font(Theme.mono(11)).foregroundStyle(Theme.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 4)
            VStack(spacing: 12) {
                Button { UIPasteboard.general.string = recipient } label: {
                    Image(systemName: "doc.on.doc").font(.system(size: 14)).foregroundStyle(Theme.teal)
                }
                Button { pendingRemoval = recipient } label: {
                    Image(systemName: "trash").font(.system(size: 14)).foregroundStyle(.red)
                }
            }
        }
    }

    private func secretRevealCard(_ secret: String) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Label("Save your secret key now", systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.rounded(15, weight: .semibold)).foregroundStyle(.orange)
                Text("This is the only key that can decrypt backups made with the pair you just generated. If you lose it, those photos are gone. Store it in a password manager.")
                    .font(.system(size: 13)).foregroundStyle(Theme.textSecondary)
                Group {
                    if showSecret {
                        Text(secret).font(Theme.mono(12)).foregroundStyle(Theme.textPrimary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text(String(repeating: "•", count: 48)).font(Theme.mono(12))
                            .foregroundStyle(Theme.textTertiary)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.surfaceHi))

                HStack {
                    GhostButton(title: showSecret ? "Hide" : "Reveal",
                                systemImage: showSecret ? "eye.slash" : "eye") { showSecret.toggle() }
                    GhostButton(title: "Copy", systemImage: "doc.on.doc", tint: Theme.teal) {
                        UIPasteboard.general.string = secret
                    }
                    GhostButton(title: "Done", systemImage: "checkmark", tint: .green) {
                        generatedSecret = nil
                    }
                }
            }
        }
    }

    private var importCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a public key").font(Theme.rounded(16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                FieldRow(label: "age recipient", placeholder: "age1… / age1se1… / age1yubikey1…",
                         text: $pastedRecipient, mono: true)
                PrimaryButton(title: "Add key", systemImage: "plus",
                              enabled: !pastedRecipient.isEmpty) {
                    do {
                        try manager.addRecipient(pastedRecipient)
                        pastedRecipient = ""
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
        }
    }

    private var generateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Generate a new pair").font(Theme.rounded(16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Creates an X25519 identity on-device, adds it to your recipients, and stores the secret in the iOS Keychain. Shown once for you to back up.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                GhostButton(title: "Generate key pair", systemImage: "sparkles", tint: Theme.violet) {
                    do {
                        let pair = try manager.generateIdentity()
                        generatedSecret = pair.secret
                        showSecret = false
                    } catch {
                        errorText = error.localizedDescription
                    }
                }
            }
        }
    }
}
