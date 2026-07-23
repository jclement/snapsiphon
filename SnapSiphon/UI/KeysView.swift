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
    @State private var confirmReplaceIdentity = false
    @State private var pendingIdentityImport: String?

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
                // Offer a phone key whenever no "★ THIS PHONE" row is visible —
                // re-adding a surviving secret, or minting a fresh pair.
                if !manager.identityIsActive {
                    generateCard
                }

                if !manager.recipients.isEmpty {
                    Text("Keys apply to future uploads. Files already backed up stay encrypted to the keys that were configured when they were uploaded.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textTertiary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(16)
            .containerRelativeFrame(.horizontal)
        }
        .background(Theme.canvas.ignoresSafeArea())
        .navigationTitle("Encryption")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Key error", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
        .confirmationDialog("Replace this phone's secret key?",
                            isPresented: Binding(get: { pendingIdentityImport != nil },
                                                 set: { if !$0 { pendingIdentityImport = nil } }),
                            titleVisibility: .visible) {
            Button("Import & replace", role: .destructive) {
                if let secret = pendingIdentityImport { performIdentityImport(secret) }
                pendingIdentityImport = nil
            }
            Button("Cancel", role: .cancel) { pendingIdentityImport = nil }
        } message: {
            Text("⚠️ This phone already holds a secret key, and importing overwrites it — reveal & save the current secret first if you haven't. The old key stays listed (public-only), so files encrypted to it remain tracked, but this phone can no longer decrypt them.")
        }
        .confirmationDialog("Discard this phone's key?", isPresented: $confirmReplaceIdentity,
                            titleVisibility: .visible) {
            Button("Discard & generate new", role: .destructive) {
                do {
                    let pair = try manager.replaceIdentity()
                    generatedSecret = pair.secret
                    showSecret = false
                } catch {
                    errorText = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("⚠️ The old secret is deleted permanently. Any backup encrypted ONLY to the old key becomes unrecoverable. A fresh pair is generated and added in its place.")
        }
        .confirmationDialog("Remove this recipient?",
                            isPresented: Binding(get: { pendingRemoval != nil },
                                                 set: { if !$0 { pendingRemoval = nil } }),
                            titleVisibility: .visible) {
            Button(pendingRemoval == manager.identityRecipient ? "Delete this phone's key" : "Remove",
                   role: .destructive) {
                if let r = pendingRemoval { manager.removeRecipient(r) }
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: {
            if pendingRemoval == manager.identityRecipient {
                Text("⚠️ This is THIS PHONE's key — removing it also deletes its secret from the Keychain. Every backup encrypted to it becomes unrecoverable unless you saved the secret (or another configured key can decrypt). Reveal and save the secret first if in doubt.")
            } else {
                Text("Future backups won't be encrypted to this key. Files already uploaded stay decryptable by whichever keys were set when they were backed up.")
            }
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
                    Pill(text: isPair ? "★ THIS PHONE" : "PUBLIC-ONLY",
                         color: isPair ? Theme.violet : Theme.teal, filled: isPair)
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
                if isPair {
                    // Reveal the secret for backup — gated behind Face ID/passcode.
                    Button {
                        Task {
                            if await DeviceAuth.authenticate(reason: "Reveal your age secret key"),
                               let secret = manager.exportSecret() {
                                generatedSecret = secret
                                showSecret = false
                            }
                        }
                    } label: {
                        Image(systemName: "eye").font(.system(size: 14)).foregroundStyle(Theme.violet)
                    }
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

    private var pastedIsSecret: Bool {
        pastedRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased().hasPrefix("age-secret-key-1")
    }

    private var importCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add a key").font(Theme.rounded(16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                Text("Paste a public key (age1… / age1se1… / age1yubikey1…) to encrypt to it — or a secret key (AGE-SECRET-KEY-…) to make it THIS PHONE's identity, e.g. when migrating an install.")
                    .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                FieldRow(label: pastedIsSecret ? "age identity (secret)" : "age recipient",
                         placeholder: "age1… / AGE-SECRET-KEY-…",
                         text: $pastedRecipient, mono: true)
                PrimaryButton(title: pastedIsSecret ? "Import as this phone's key" : "Add key",
                              systemImage: pastedIsSecret ? "key.horizontal.fill" : "plus",
                              enabled: !pastedRecipient.isEmpty) {
                    if pastedIsSecret {
                        requestIdentityImport()
                    } else {
                        do {
                            try manager.addRecipient(pastedRecipient)
                            pastedRecipient = ""
                            // New key can't read anything already written —
                            // roll a fresh checkpoint so it can at least read
                            // the index (and everything from here on).
                            engine.noteRecipientsChanged()
                        } catch {
                            errorText = error.localizedDescription
                        }
                    }
                }
            }
        }
    }

    // MARK: Identity import

    private func requestIdentityImport() {
        let trimmed = pastedRecipient.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let identity = try? Age.Identity(bech32: trimmed) else {
            errorText = "That doesn't parse as an age secret key."
            return
        }
        // Replacing a DIFFERENT existing phone secret is destructive — confirm.
        if manager.hasIdentity, manager.identityRecipient != identity.recipient.bech32 {
            pendingIdentityImport = trimmed
        } else {
            performIdentityImport(trimmed)
        }
    }

    private func performIdentityImport(_ secret: String) {
        do {
            try manager.importIdentity(secret)
            pastedRecipient = ""
            engine.noteRecipientsChanged()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private var generateCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("This phone's key").font(Theme.rounded(16, weight: .semibold))
                    .foregroundStyle(Theme.textPrimary)
                if manager.hasIdentity {
                    // A secret survives in the Keychain but its row was removed.
                    // Re-adding it keeps old backups decryptable — never mint a
                    // replacement over it.
                    Text("This phone still holds its secret key, but it isn't in your recipient list. Re-add it to keep using it (backups already encrypted to it stay recoverable).")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    GhostButton(title: "Re-add this phone's key", systemImage: "arrow.uturn.backward",
                                tint: Theme.violet) {
                        if !manager.reactivateIdentity() {
                            errorText = "Could not re-add the phone's key."
                        }
                    }
                    GhostButton(title: "Discard & generate a new key…", systemImage: "exclamationmark.arrow.circlepath",
                                tint: .red) {
                        confirmReplaceIdentity = true
                    }
                } else {
                    Text("Creates an X25519 identity on-device, adds it to your recipients, and stores the secret in the iOS Keychain. Reveal it any time with Face ID to back it up.")
                        .font(.system(size: 12)).foregroundStyle(Theme.textSecondary)
                    GhostButton(title: "Generate & add this phone's key", systemImage: "sparkles",
                                tint: Theme.violet) {
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
}
