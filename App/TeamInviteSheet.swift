import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TeamInviteSheet: View {
    let api: WorkspaceAPI
    let workspace: Workspace
    @Environment(\.dismiss) private var dismiss
    @State private var code: String?
    @State private var failed = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Teammates can enter this code when joining \(workspace.name).")
                        .foregroundStyle(MobileTheme.secondary)
                    if let code {
                        HStack {
                            Text(code)
                                .font(.title2.weight(.semibold).monospaced())
                                .minimumScaleFactor(0.65)
                                .accessibilityLabel("Workspace join code \(code)")
                            Spacer(minLength: 4)
                            Button {
                                UIPasteboard.general.setItems([[UTType.plainText.identifier: code]], options: [
                                    .localOnly: true, .expirationDate: Date().addingTimeInterval(300)
                                ])
                                copied = true
                            } label: {
                                Image(systemName: copied ? "checkmark" : "document.on.document")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel(copied ? "Join code copied" : "Copy join code")
                            ShareLink(item: code) {
                                Image(systemName: "square.and.arrow.up")
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .accessibilityLabel("Share join code")
                        }
                        Text("Valid for 7 days or 20 joins. Share it only with your team.")
                            .font(.footnote).foregroundStyle(MobileTheme.secondary)
                    } else if failed {
                        Text("Couldn’t create a join code.")
                        Button("Try again") { Task { await load() } }
                    } else {
                        ProgressView("Creating join code")
                    }
                    Button("Open workspace") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .padding(24)
                .frame(maxWidth: 520, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .aedrovaScreen()
            .navigationTitle("Invite your team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Skip") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard code == nil else { return }
        failed = false
        do { code = try await api.createJoinCode(workspace: workspace.id) }
        catch { if !Task.isCancelled { failed = true } }
    }
}
