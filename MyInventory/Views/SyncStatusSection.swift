//
//  SyncStatusSection.swift
//  MyInventory
//
//  The Settings "Cloud Sync" section (S3 Part C, design §6). It renders purely from
//  the injected `SyncEngine`'s observable `SyncState` and drives the triggers
//  (sign in / sync now / sign out). It replaces the old hard-coded "Local only" row.
//
//  Until `DriveTransport` + real Google sign-in land (C-1), the engine is backed by
//  the in-memory fake, so the Sign-in button is only interactive under the `-syncDemo`
//  launch argument (`demoEnabled`); a normal build shows the forward-looking
//  "coming soon" state instead of pretending to sync.
//

import SwiftUI
import SwiftData

struct SyncStatusSection: View {
    @Environment(SyncEngine.self) private var engine

    /// Whether sign-in is live. False in a normal build (no real Drive backend yet) →
    /// the button is disabled and the footer says sync is coming; true under `-syncDemo`.
    var demoEnabled: Bool = false

    var body: some View {
        Section {
            content
        } header: {
            Text("Cloud Sync")
        } footer: {
            Text(footerText)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch engine.state {
        case .signedOut:
            Button {
                engine.signIn()
            } label: {
                Label("Sign in to Google Drive", systemImage: "person.crop.circle.badge.plus")
            }
            .disabled(!demoEnabled)

        case .idle:
            LabeledContent("Status", value: "Not synced yet")
            syncNowButton
            signOutButton

        case .synced(let at):
            LabeledContent("Status") {
                // `Text(_, style: .relative)` self-updates while the view is on screen;
                // the `format: .relative(...)` initializer formats ONCE at render, so the
                // row would freeze at "Synced now" the whole time Settings stays open.
                (Text("Synced ") + Text(at, style: .relative) + Text(" ago"))
                    .foregroundStyle(.secondary)
            }
            syncNowButton
            signOutButton

        case .syncing:
            HStack(spacing: Theme.spacing4) {
                ProgressView()
                Text("Syncing…").foregroundStyle(.secondary)
            }
            syncNowButton   // disabled while syncing

        case .error(let reason):
            LabeledContent("Status") {
                Text(errorText(reason)).foregroundStyle(.red)
            }
            if reason == .authExpired {
                Button {
                    engine.signIn()
                } label: {
                    Label("Sign in again", systemImage: "person.crop.circle.badge.exclamationmark")
                }
                .disabled(!demoEnabled)
            } else {
                syncNowButton
            }
            signOutButton
        }
    }

    private var syncNowButton: some View {
        Button {
            Task { await engine.syncNow() }
        } label: {
            Label("Sync Now", systemImage: "arrow.triangle.2.circlepath")
        }
        .disabled(engine.state == .syncing)
    }

    private var signOutButton: some View {
        Button(role: .destructive) {
            engine.signOut()
        } label: {
            Label("Sign Out", systemImage: "person.crop.circle.badge.minus")
        }
    }

    private func errorText(_ reason: SyncError) -> String {
        switch reason {
        case .offline:        return "You’re offline — sync will resume when you’re back online."
        case .authExpired:    return "Your Google sign-in expired. Sign in again to keep syncing."
        case .decryptFailed:  return "Wrong passphrase for this Drive file — the backup couldn’t be opened."
        case .driveError(let message): return message
        }
    }

    private var footerText: String {
        if demoEnabled {
            return "Preview: syncs to a local in-memory store so the controls can be exercised end-to-end. Google Drive sync arrives in a later update."
        }
        switch engine.state {
        case .signedOut:
            return "Sign in to Google Drive to keep your supplies in sync across your iPad and Android tablet. This arrives in a later update — until then, use the encrypted backup above to move data between devices."
        default:
            return "Your data syncs end-to-end encrypted through your own Google Drive; the cloud only ever sees ciphertext."
        }
    }
}

#Preview("Signed out") {
    @Previewable @State var engine = previewEngine(signedIn: false)
    Form { SyncStatusSection(demoEnabled: true) }
        .environment(engine)
}

#Preview("Signed in") {
    @Previewable @State var engine = previewEngine(signedIn: true)
    Form { SyncStatusSection(demoEnabled: true) }
        .environment(engine)
}

@MainActor
private func previewEngine(signedIn: Bool) -> SyncEngine {
    let container = try! ModelContainer(
        for: SupplyContext.self, SupplyCategory.self, SupplyItem.self, CheckRecord.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true))
    return SyncEngine.localPreview(modelContext: container.mainContext, settings: nil, signedIn: signedIn)
}
