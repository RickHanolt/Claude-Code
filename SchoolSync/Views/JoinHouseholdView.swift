import SwiftUI
import SwiftData
import UIKit
import CryptoKit

/// Joining a household, from the viewing phone.
///
/// This is the only setup a viewer ever does, and it has to survive being done
/// once, by someone who didn't ask for an app, standing in a kitchen. So: one
/// screen, one button, and a typed fallback for every way a camera can decline
/// to work.
struct JoinHouseholdView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    /// Named so the owner's list reads like people rather than hardware. The
    /// device's own name is usually already "Grandma's iPhone", so it's the
    /// right default and usually the right answer.
    @State private var label = UIDevice.current.name
    @State private var isScanning = false
    @State private var pastedCode = ""
    @State private var isJoining = false
    @State private var error: String?
    @State private var cameraProblem: String?

    var body: some View {
        Form {
            Section {
                TextField("This phone's name", text: $label)
                    .autocorrectionDisabled()
            } header: {
                Text("Who's this")
            } footer: {
                Text("Only shown to whoever shared the schedule with you, so they know which phone is which.")
            }

            Section {
                Button {
                    cameraProblem = nil
                    isScanning = true
                } label: {
                    Label("Scan the code", systemImage: "qrcode.viewfinder")
                }
                .disabled(isJoining)
            } footer: {
                Text("Ask them to open SchoolSync, go to Settings → Sharing, and tap Invite a phone.")
            }

            Section {
                TextField("Paste the code", text: $pastedCode, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .lineLimit(1...4)
                    .font(.caption.monospaced())
                Button("Join") {
                    Task { await join(scanned: pastedCode) }
                }
                .disabled(isJoining || pastedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("No camera?")
            } footer: {
                if let cameraProblem {
                    Text("\(cameraProblem) You can paste the code instead — they can send it from that same Invite screen.")
                        .foregroundStyle(.orange)
                } else {
                    Text("They can send the code by message instead, from that same Invite screen.")
                }
            }

            if isJoining {
                Section { HStack { ProgressView(); Text("Joining…") } }
            }

            if let error {
                Section { Text(error).font(.callout).foregroundStyle(.red) }
            }
        }
        .navigationTitle("Join with a code")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isScanning) {
            NavigationStack {
                QRScannerView(
                    onFound: { scanned in
                        isScanning = false
                        Task { await join(scanned: scanned) }
                    },
                    onFailure: { reason in
                        isScanning = false
                        cameraProblem = reason
                    }
                )
                .ignoresSafeArea()
                .navigationTitle("Point at the code")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { isScanning = false }
                    }
                }
            }
        }
    }

    private func join(scanned: String) async {
        guard !isJoining else { return }
        isJoining = true
        defer { isJoining = false }
        error = nil

        let trimmed = scanned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let invite = ViewerInvite.decode(trimmed) else {
            error = "That doesn't look like a SchoolSync code. Ask them to send it again."
            return
        }

        // Checked before redeeming, not after. The code works exactly once, so
        // spending it on an invite whose key is unreadable would leave this
        // phone joined to a household it can't read and needing a second code
        // for no reason the person holding it could possibly guess.
        let key: SymmetricKey
        do {
            key = try HouseholdCrypto.decode(invite.key)
        } catch {
            error = "That code is incomplete. Ask them to make a new one."
            return
        }

        do {
            let token = try await ViewerClient.redeem(invite: invite, label: label)

            ViewerSettings.viewerBaseURL = URL(string: invite.url)
            ViewerSettings.householdKey = key
            // Written last: `role` reads the token, so until this line lands the
            // app is still whatever it was, and a failure above leaves nothing
            // half-joined behind it.
            ViewerSettings.viewerToken = token
            ViewerSettings.hasChosenRole = true

            // Fetch straight away. Waiting for the next launch would show an
            // empty app to someone who has just done everything right.
            try? await SnapshotService(modelContext: modelContext)
                .refreshFromSnapshot(calendarSync: CalendarSyncService())
            AutoSync.markRun()

            dismiss()
        } catch {
            self.error = "Couldn't join — \(error.localizedDescription)"
        }
    }
}
