import SwiftUI
import UIKit

struct AccountSettingsSheet: View {
    let store: WorkspaceStore
    @Environment(\.dismiss) private var dismiss
    @State private var profile: MobileProfile?
    @State private var photo: UIImage?

    var body: some View {
        NavigationStack {
            List {
                if !store.isDemo {
                    if let name = profile?.displayName {
                        HStack(spacing: 12) {
                            if let photo {
                                Image(uiImage: photo).resizable().scaledToFill()
                                    .frame(width: 42, height: 42).clipShape(.circle)
                                    .accessibilityHidden(true)
                            } else {
                                AedrovaInitials(name: name, size: 42, emphasized: true)
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(name).font(.headline)
                                if let username = profile?.username {
                                    Text("@" + username).font(.footnote).foregroundStyle(MobileTheme.secondary)
                                }
                            }
                        }
                    }
                    NavigationLink {
                        BlockedTeammatesView(store: store)
                    } label: {
                        Label("Blocked teammates", systemImage: "hand.raised")
                    }
                    Link(destination: URL(string: "https://aedrova.com/privacy")!) {
                        Label("Privacy Policy", systemImage: "hand.raised.square")
                    }
                    Link(destination: URL(string: "https://aedrova.com/support")!) {
                        Label("Contact support", systemImage: "questionmark.circle")
                    }
                    NavigationLink {
                        AccountDeletionView(api: store.api)
                    } label: {
                        Label("Delete account", systemImage: "trash")
                            .foregroundStyle(.red)
                    }
                }
                Button {
                    dismiss()
                    Task { await store.signOut() }
                } label: {
                    Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            .aedrovaPanelRows()
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task {
                guard !store.isDemo else { return }
                profile = try? await store.api.myProfile()
                if let path = profile?.avatarPath, let data = try? await store.api.profilePhoto(path: path) {
                    photo = UIImage(data: data)
                }
            }
        }
    }
}

private struct BlockedTeammatesView: View {
    let store: WorkspaceStore
    @State private var ready = false
    @State private var failure: String?

    var body: some View {
        List {
            if !ready && failure == nil { ProgressView("Loading blocked teammates") }
            if let failure { Text(failure).foregroundStyle(MobileTheme.secondary) }
            if ready && store.blockedPeople.isEmpty { Text("No blocked teammates") }
            ForEach(store.blockedPeople.sorted { $0.uuidString < $1.uuidString }, id: \.self) { person in
                HStack {
                    Text(store.knownChatNames[person] ?? "Teammate · " + person.uuidString.suffix(6))
                    Spacer()
                    Button("Unblock") {
                        Task {
                            do {
                                try await store.setChatBlock(person, workspace: nil, blocked: false)
                                failure = nil
                            } catch {
                                failure = "Couldn’t unblock this teammate. Try again."
                            }
                        }
                    }
                }
            }
        }
        .aedrovaPanelRows()
        .navigationTitle("Blocked teammates")
        .task {
            do {
                try await store.refreshChatBlocks()
                ready = true
            } catch {
                failure = "Couldn’t load blocked teammates."
            }
        }
    }
}

private struct AccountDeletionView: View {
    let api: WorkspaceAPI
    @State private var receipt: WorkspaceAPI.DeletionReceipt?
    @State private var loaded = false
    @State private var isSubmitting = false
    @State private var confirming = false
    @State private var failure: String?
    @State private var revocationResult: String?
    @State private var revoking = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let receipt {
                    Text(receipt.completed ? "Account deletion complete" : "Deletion request received")
                        .font(.title2.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    if !receipt.completed {
                        Text("Allow up to 30 days. We’ll email you when deletion is complete or if we need more information.")
                        if let revocationResult {
                            Text(revocationResult).foregroundStyle(MobileTheme.secondary)
                        }
                        if revoking {
                            ProgressView("Revoking Apple sign-in access")
                        } else if revocationResult != "Apple sign-in access revoked." {
                            DisclosureGroup("Signed in with Apple?") {
                                VStack(alignment: .leading, spacing: 8) {
                                    Button("Revoke Apple sign-in access") { Task { await revokeApple() } }
                                    Text("You can also remove Aedrova in Settings → Apple Account → Sign in with Apple.")
                                        .font(.footnote).foregroundStyle(MobileTheme.secondary)
                                }.padding(.top, 6)
                            }
                        }
                    }
                    Text("Request reference")
                        .font(.subheadline.weight(.medium))
                    Text(receipt.id.uuidString)
                        .font(.footnote)
                        .foregroundStyle(MobileTheme.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("Request permanent deletion of your Aedrova account and associated personal data. Some records may be retained where legally required.")
                    Text("Allow up to 30 days. We’ll email you when deletion is complete or if we need more information.")
                        .foregroundStyle(MobileTheme.secondary)
                    if let failure {
                        Text(failure).foregroundStyle(MobileTheme.secondary)
                        if !loaded {
                            Button("Try again") { Task { await load() } }
                        }
                    }
                    if isSubmitting || (!loaded && failure == nil) {
                        ProgressView(isSubmitting ? "Submitting request" : "Checking request status")
                    } else if loaded {
                        Button("Request account deletion", role: .destructive) { confirming = true }
                            .buttonStyle(.bordered)
                            .tint(.red)
                    }
                }
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .aedrovaScreen()
        .navigationTitle("Delete account")
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(isSubmitting)
        .interactiveDismissDisabled(isSubmitting)
        .task { await load() }
        .confirmationDialog("Request permanent account deletion?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Request deletion", role: .destructive) { Task { await submit() } }
        } message: {
            Text("You’ll lose access to this Aedrova account once deletion is complete.")
        }
    }

    private func load() async {
        failure = nil
        do {
            receipt = try await api.accountDeletionRequest()
            loaded = true
        } catch {
            guard !Task.isCancelled else { return }
            failure = errorMessage(error, fallback: "Couldn’t check your deletion request. Try again.")
        }
    }

    private func submit() async {
        guard !isSubmitting, receipt == nil else { return }
        isSubmitting = true
        failure = nil
        defer { isSubmitting = false }
        do {
            receipt = try await api.requestAccountDeletion()
            await revokeApple(automatic: true)
        } catch {
            failure = errorMessage(error, fallback: "Couldn’t confirm your request. You can safely try again.")
        }
    }

    private func revokeApple(automatic: Bool = false) async {
        guard !revoking, receipt?.completed == false else { return }
        revoking = true
        defer { revoking = false }
        do {
            if try await api.revokeAppleForDeletion() {
                revocationResult = "Apple sign-in access revoked."
            } else if !automatic {
                revocationResult = "To revoke Apple access, remove Aedrova in your Apple Account settings."
            }
        } catch {
            revocationResult = "Your deletion request is saved. Apple access couldn’t be revoked yet."
        }
    }

    private func errorMessage(_ error: Error, fallback: String) -> String {
        switch error {
        case WorkspaceError.status(404): "Account deletion requests are temporarily unavailable. Try again later."
        case WorkspaceError.signIn, WorkspaceError.status(401), WorkspaceError.status(403):
            "Sign in again to access your account deletion request."
        case WorkspaceError.rateLimited(let seconds): WorkspaceError.rateLimited(seconds).message
        default: fallback
        }
    }
}
