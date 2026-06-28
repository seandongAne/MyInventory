//
//  EncryptedBackupSheets.swift
//  MyInventory
//
//  The user-facing flows for the SCBK1 encrypted backup (Phase-1 E2EE). The crypto
//  core lives in `BackupCrypto`; this file is only the UI:
//
//    • `EncryptedBackupSheet`  — pick a passphrase, encrypt the JSON export off the
//      main thread (Argon2id is deliberately slow), then show the one-time recovery
//      key and a ShareLink to save/send the `.scbk` file.
//    • `EncryptedRestoreSheet` — unlock a parsed envelope with either the passphrase
//      or the recovery key (decryption runs off-main too), handing the decrypted
//      JSON back to the caller to merge.
//
//  The `.scbk` is the cross-platform, end-to-end-encrypted backup: a cloud drive
//  only ever holds this ciphertext, never the inventory.
//

import SwiftUI
import UIKit

// MARK: - Export

/// Creates an encrypted `.scbk` backup. Phases: passphrase entry → (heavy
/// encryption while a spinner shows) → one-time recovery key + share.
struct EncryptedBackupSheet: View {
    /// Produces the plaintext JSON to encrypt. Runs on the main actor because it
    /// reads the model context; the caller wires it to `DataExporter.makeExport`.
    let makePlaintext: @MainActor () throws -> String

    @Environment(\.dismiss) private var dismiss

    private enum Phase { case entry, working, done }
    @State private var phase: Phase = .entry
    @State private var passphrase = ""
    @State private var confirm = ""
    @State private var recoveryKey: String?
    @State private var scbkURL: URL?
    @State private var errorMessage: String?

    private let minPassphraseLength = 8

    private var passphraseValid: Bool {
        passphrase.count >= minPassphraseLength && passphrase == confirm
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .entry, .working: entryForm
                case .done: doneForm
                }
            }
            .navigationTitle("Encrypted Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(phase == .done ? "Done" : "Cancel") { dismiss() }
                        .disabled(phase == .working)
                }
            }
            .interactiveDismissDisabled(phase == .working)
            .alert("Couldn’t create backup", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
        }
    }

    private var entryForm: some View {
        Form {
            Section {
                SecureField("Passphrase", text: $passphrase)
                    .textContentType(.newPassword)
                SecureField("Confirm passphrase", text: $confirm)
                    .textContentType(.newPassword)
            } header: {
                Text("Choose a passphrase")
            } footer: {
                Text("At least \(minPassphraseLength) characters. You’ll need this passphrase to restore the backup on any device — there’s no way to recover it if you forget it. You’ll also get a one-time recovery key as a fallback.")
            }

            Section {
                Button {
                    createBackup()
                } label: {
                    if phase == .working {
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Encrypting…")
                        }
                    } else {
                        Text("Create Backup")
                    }
                }
                .disabled(!passphraseValid || phase == .working)
            }
        }
    }

    private var doneForm: some View {
        Form {
            Section {
                Label("Backup encrypted", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
            }

            Section {
                Text(recoveryKey ?? "")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button {
                    if let recoveryKey { UIPasteboard.general.string = recoveryKey }
                } label: {
                    Label("Copy Recovery Key", systemImage: "doc.on.doc")
                }
            } header: {
                Text("Recovery key")
            } footer: {
                Text("Write this down and keep it somewhere safe — it can unlock this backup if you forget the passphrase. This is the only time it’s shown.")
            }

            Section {
                if let scbkURL {
                    ShareLink(item: scbkURL,
                              preview: SharePreview(scbkURL.lastPathComponent,
                                                    image: Image(systemName: "lock.doc"))) {
                        Label("Save or Share Backup…", systemImage: "square.and.arrow.up")
                    }
                }
            } footer: {
                Text("Save the encrypted file to Files, a cloud drive, or send it to your other device. It’s useless to anyone without your passphrase or recovery key.")
            }
        }
    }

    private func createBackup() {
        phase = .working
        let pass = passphrase
        Task {
            do {
                let plaintext = try makePlaintext()
                let (url, rk) = try await Task.detached(priority: .userInitiated) {
                    let (envelope, recovery) = try BackupCrypto.encryptBackup(
                        plaintextUtf8: plaintext, passphrase: pass)
                    let data = try BackupCrypto.serializeEnvelope(envelope)
                    let fileURL = FileManager.default.temporaryDirectory
                        .appendingPathComponent(DataExporter.defaultFilename())
                        .appendingPathExtension("scbk")
                    try data.write(to: fileURL, options: .atomic)
                    return (fileURL, recovery)
                }.value
                scbkURL = url
                recoveryKey = rk
                phase = .done
                Haptics.success()
            } catch {
                errorMessage = error.localizedDescription
                phase = .entry
            }
        }
    }
}

// MARK: - Restore

/// One picked-and-parsed `.scbk` envelope waiting to be unlocked. Wraps the
/// envelope with an id so it can drive `.sheet(item:)`.
struct PendingRestore: Identifiable {
    let id = UUID()
    let envelope: BackupCrypto.Envelope
}

/// Unlocks a parsed SCBK1 envelope with the passphrase or the recovery key, then
/// hands the decrypted JSON to `onDecrypted` (the caller does the additive merge).
struct EncryptedRestoreSheet: View {
    let envelope: BackupCrypto.Envelope
    /// Called with the decrypted plaintext JSON on success.
    let onDecrypted: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    enum Mode: String, CaseIterable {
        case passphrase = "Passphrase"
        case recoveryKey = "Recovery key"
    }

    @State private var mode: Mode = .passphrase
    @State private var secret = ""
    @State private var working = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Unlock with", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    if mode == .passphrase {
                        SecureField("Passphrase", text: $secret)
                            .textContentType(.password)
                    } else {
                        TextField("Recovery key", text: $secret, axis: .vertical)
                            .font(.system(.body, design: .monospaced))
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                    }
                } footer: {
                    Text(mode == .passphrase
                         ? "Enter the passphrase you chose when creating this backup."
                         : "Enter the recovery key shown when the backup was created. Dashes, spaces, and letter case don’t matter.")
                }

                Section {
                    Button {
                        unlock()
                    } label: {
                        if working {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Decrypting…")
                            }
                        } else {
                            Text("Restore")
                        }
                    }
                    .disabled(secret.isEmpty || working)
                }
            }
            .navigationTitle("Restore Backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(working)
                }
            }
            .interactiveDismissDisabled(working)
            .alert("Couldn’t restore", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("OK", role: .cancel) { errorMessage = nil }
            } message: {
                if let errorMessage { Text(errorMessage) }
            }
        }
    }

    private func unlock() {
        working = true
        let currentMode = mode
        let currentSecret = secret
        let env = envelope
        Task {
            do {
                let plaintext = try await Task.detached(priority: .userInitiated) { () throws -> String in
                    switch currentMode {
                    case .passphrase:
                        return try BackupCrypto.decryptWithPassphrase(env, passphrase: currentSecret)
                    case .recoveryKey:
                        return try BackupCrypto.decryptWithRecoveryKey(env, recoveryKey: currentSecret)
                    }
                }.value
                onDecrypted(plaintext)
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
                working = false
            }
        }
    }
}
