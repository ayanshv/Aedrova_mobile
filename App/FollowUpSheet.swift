import SwiftUI

struct FollowUpSheet: View {
    let store: WorkspaceStore
    let user: UUID
    let scope: ChatScope
    let reply: ChatView.Row

    init(store: WorkspaceStore, user: UUID, scope: ChatScope, reply: ChatView.Row, starter: String = "") {
        self.store = store
        self.user = user
        self.scope = scope
        self.reply = reply
        _question = State(initialValue: starter)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var answer: ManagedFollowUp.Answer?
    @State private var working = false
    @State private var saved = false
    @State private var error: String?
    @State private var work: Task<Void, Never>?
    @State private var showingConsent = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(ChatView.displayText(reply.body))
                        .font(.subheadline)
                        .foregroundStyle(MobileTheme.secondary)
                        .lineLimit(4)
                    if let answer, saved {
                        Text(answer.body).textSelection(.enabled)
                        Text("This follow-up uses the selected reply as context. Open the original conversation to review it alongside your team’s messages.")
                            .font(.footnote)
                            .foregroundStyle(MobileTheme.secondary)
                        Label("Saved to your private reply history", systemImage: "checkmark")
                            .font(.footnote)
                            .foregroundStyle(MobileTheme.muted)
                    } else {
                        TextField("Ask about this reply", text: $question, axis: .vertical)
                            .lineLimit(3...6)
                            .padding(12)
                            .background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 12))
                            .disabled(working)
                        Text("Uses your workspace’s AI allowance.")
                            .font(.footnote)
                            .foregroundStyle(MobileTheme.muted)
                    }
                    if let error { Text(error).font(.subheadline).foregroundStyle(MobileTheme.secondary) }
                    if working {
                        HStack(spacing: 8) {
                            Text(answer == nil ? "Aedrova is preparing a reply" : "Saving reply")
                                .font(.subheadline)
                            AedrovaActivityDots()
                        }
                    } else if !saved {
                        Button(answer == nil ? "Ask Aedrova" : "Retry saving") {
                            if answer == nil { showingConsent = true }
                            else { work = Task { await submit(consent: false) } }
                        }
                        .buttonStyle(AedrovaTextAction())
                        .disabled(answer == nil && (trimmed.isEmpty || trimmed.unicodeScalars.count > 2000))
                    }
                }
                .frame(maxWidth: 520, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
            }
            .aedrovaScreen()
            .navigationTitle("Ask a follow-up")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .confirmationDialog("Share with OpenAI?", isPresented: $showingConsent, titleVisibility: .visible) {
            Button("Allow and send") { work = Task { await submit(consent: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Aedrova sends your question and the selected reply to OpenAI to generate an answer. This can include personal information in the reply.")
        }
        .onDisappear { work?.cancel() }
    }

    private var trimmed: String { question.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func submit(consent: Bool) async {
        guard !working, !saved, store.user == user else { return }
        working = true
        error = nil
        defer { working = false }
        do {
            let generated: ManagedFollowUp.Answer
            if let answer { generated = answer }
            else {
                generated = try await store.api.followUp(id: UUID(), workspace: scope.workspace,
                                                         conversation: scope.channel, parent: scope.parent,
                                                         reply: reply.id, question: trimmed, user: user, consent: consent)
                try Task.checkCancellation()
                answer = generated
            }
            try await store.api.saveFollowUp(generated, workspace: scope.workspace, conversation: scope.channel,
                                             parent: scope.parent, user: user)
            try Task.checkCancellation()
            saved = true
        } catch is CancellationError {
        } catch let failure {
            if (failure as? WorkspaceError)?.isAccessFailure == true {
                answer = nil
                error = FollowUpError.unavailable.message
            } else if answer != nil {
                error = FollowUpError.saveFailed.message
            } else {
                error = (failure as? FollowUpError)?.message ?? message(for: failure)
            }
        }
    }
}
