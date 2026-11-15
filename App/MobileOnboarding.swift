import SwiftUI

enum WorkspaceSetup: String, Identifiable {
    case choose, create, join

    var id: Self { self }

    var title: String {
        switch self {
        case .choose: "Set up your workspace"
        case .create: "Create a workspace"
        case .join: "Join a workspace"
        }
    }

    func validated(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch self {
        case .choose: return nil
        case .create:
            return (1...80).contains(value.unicodeScalars.count)
                && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ? value : nil
        case .join:
            if value.range(of: #"^A2(-[0-9A-F]{4}){4}$"#, options: [.regularExpression, .caseInsensitive]) != nil {
                return value.uppercased()
            }
            return value.utf8.count == 64 && value.utf8.allSatisfy {
                (48...57).contains($0) || (97...102).contains($0)
            } ? value : nil
        }
    }
}

struct WorkspaceSetupEntry: View {
    let select: (WorkspaceSetup) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image("AedrovaMark").resizable().scaledToFit()
                .frame(width: 52, height: 52).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Bring your team together")
                    .font(.title2.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                Text("Start a workspace or join one with a teammate’s invite code.")
                    .font(.subheadline)
                    .foregroundStyle(MobileTheme.muted)
            }
            VStack(spacing: 6) {
                Button { select(.create) } label: {
                    Label("Create a workspace", systemImage: "plus")
                        .frame(maxWidth: .infinity, minHeight: 34)
                }
                .buttonStyle(.borderedProminent)
                Button { select(.join) } label: {
                    Text("I have an invite code").frame(maxWidth: .infinity, minHeight: 36)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MobileTheme.link)
            }
            .controlSize(.large)
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 22))
    }
}

struct WorkspaceSetupSheet: View {
    let api: WorkspaceAPI
    let knownWorkspaces: Set<UUID>
    let didLoad: ([Workspace]) -> Void
    let didOpen: (Workspace) -> Void
    @Environment(\.dismiss) private var dismiss
    @State var step: WorkspaceSetup
    @State private var input = ""
    @State private var working = false
    @State private var notice: String?
    @State private var shouldCheck = false
    @State private var confirmedID: UUID?
    @State private var foundWorkspaces = false
    @FocusState private var inputFocused: Bool
    @AccessibilityFocusState private var noticeFocused: Bool

    var body: some View {
        NavigationStack {
            ScrollView {
                Group {
                    if step == .choose {
                        WorkspaceSetupEntry { step = $0 }
                    } else {
                        form
                    }
                }
                .frame(maxWidth: 500)
                .padding(22)
                .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle(step.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .choose && !shouldCheck && !working {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            input = ""
                            notice = nil
                            step = .choose
                        } label: { Image(systemName: "chevron.backward") }
                        .accessibilityLabel("Back to setup options")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .accessibilityLabel("Close setup")
                        .disabled(working)
                }
            }
            .aedrovaScreen()
        }
        .tint(MobileTheme.accent)
        .interactiveDismissDisabled(working)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            AedrovaState(title: step == .create ? "Give your team a home" : "Enter your invite code",
                         detail: step == .create
                            ? "You’ll start in #general, your team’s first channel."
                            : "Paste the join code your teammate shared.",
                         symbol: step == .create ? "square.stack" : "person.badge.plus")
                .padding(.bottom, 4)

            VStack(alignment: .leading, spacing: 8) {
                let label = step == .create ? "Workspace name" : "Invite code"
                Text(label).font(.subheadline.weight(.semibold)).accessibilityHidden(true)
                Group {
                    if step == .create {
                        TextField("e.g. Studio North", text: $input).textContentType(.organizationName)
                    } else {
                        SecureField("Paste invite code", text: $input)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }
                .accessibilityLabel(label)
                .focused($inputFocused)
                .submitLabel(.go)
                .onSubmit { if canSubmit { start() } }
                .padding(.horizontal, 14)
                .frame(minHeight: 52)
                .background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                .disabled(working || shouldCheck || foundWorkspaces)
                .onChange(of: input) { _, _ in
                    if !working && !shouldCheck { notice = nil }
                }
                if step == .join {
                    Text("For A2 codes, keep the dashes. Uppercase and lowercase both work.")
                        .font(.footnote)
                        .foregroundStyle(MobileTheme.secondary)
                }
            }
            if let notice {
                Label(notice, systemImage: "info.circle")
                    .font(.subheadline)
                    .foregroundStyle(MobileTheme.secondary)
                    .accessibilityFocused($noticeFocused)
            }
            Button(action: start) {
                HStack(spacing: 10) {
                    if working { ProgressView().tint(.white).accessibilityHidden(true) }
                    Text(actionTitle)
                }
                .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canSubmit)
        }
    }

    private var actionTitle: String {
        if foundWorkspaces { return "View workspaces" }
        if working { return shouldCheck ? "Checking workspaces…" : step == .create ? "Creating workspace…" : "Joining workspace…" }
        if shouldCheck { return "Check workspaces" }
        return step.title
    }

    private var canSubmit: Bool {
        !working && (foundWorkspaces || shouldCheck || step.validated(input) != nil)
    }

    private func start() {
        guard canSubmit else { return }
        if foundWorkspaces { dismiss(); return }
        inputFocused = false
        working = true
        notice = nil
        Task {
            defer { working = false }
            if shouldCheck { await checkWorkspaces(); return }
            guard let value = step.validated(input) else { return }
            do {
                confirmedID = if step == .create {
                    try await api.onboardWorkspace(name: value)
                } else {
                    try await api.acceptInvitation(token: value)
                }
                shouldCheck = true
                await checkWorkspaces()
            } catch WorkspaceError.status(403) where step == .join {
                show("This invite couldn’t be accepted. Check the code or ask your teammate for a new one.")
            } catch WorkspaceError.status(400) {
                show("Aedrova couldn’t use these details. Check them and try again.")
            } catch WorkspaceError.status(403) {
                show("This account can’t create a workspace right now.")
            } catch WorkspaceError.rateLimited(let seconds) {
                show(WorkspaceError.rateLimited(seconds).message)
            } catch WorkspaceError.signIn, WorkspaceError.status(401) {
                show("Your session ended. Close setup and sign in again.")
            } catch {
                shouldCheck = true
                show("The connection dropped before Aedrova could confirm this. Check your workspaces before trying again.")
            }
        }
    }

    private func checkWorkspaces() async {
        do {
            let rows = try await api.workspaces()
            didLoad(rows)
            if let confirmedID {
                guard let workspace = rows.first(where: { $0.id == confirmedID }) else {
                    show("Setup was accepted, but this workspace isn’t in your active list. Check again or return to your workspaces.")
                    return
                }
                didOpen(workspace)
                dismiss()
            } else if rows.contains(where: { !knownWorkspaces.contains($0.id) }) {
                foundWorkspaces = true
                show("There’s a new workspace in your list. Open it before trying setup again.")
            } else {
                shouldCheck = false
                show("No new workspace is visible. You can try again or check your workspace list.")
            }
        } catch {
            show("Couldn’t check your workspaces. Try checking again when you’re connected.")
        }
    }

    private func show(_ text: String) {
        notice = text
        noticeFocused = true
    }
}

enum MobileOnboardingGoal: String, CaseIterable, Identifiable {
    case catchUp, build, explore, skipped

    var id: Self { self }

    var title: String {
        switch self {
        case .catchUp: "Catch up with my team"
        case .build: "Build something"
        case .explore: "Explore Aedrova"
        case .skipped: "Skip for now"
        }
    }

    var icon: String {
        switch self {
        case .catchUp: "bubble.left.and.bubble.right"
        case .build: "hammer"
        case .explore: "compass.drawing"
        case .skipped: "sidebar.left"
        }
    }

    var detail: String {
        switch self {
        case .catchUp: "Find decisions and open questions in workspace search."
        case .build: "Read Agent updates and ask about a reply. Start builds on desktop."
        case .explore, .skipped: "Open the sidebar to find channels, DMs, and Activity."
        }
    }
}

struct MobileGoalSheet: View {
    let workspace: Workspace
    let select: (MobileOnboardingGoal) -> Void

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    AedrovaLockup()
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 6)
                    Text(workspace.name)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MobileTheme.secondary)
                    Text("What are you here to do?")
                        .font(.largeTitle.weight(.semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("You can always change course. Private channels are visible to their members.")
                        .font(.subheadline)
                        .foregroundStyle(MobileTheme.muted)
                    ForEach([MobileOnboardingGoal.catchUp, .build, .explore]) { goal in
                        Button { select(goal) } label: {
                            HStack(spacing: 12) {
                                AedrovaGlyph(symbol: goal.icon, highlighted: true)
                                Text(goal.title).font(.headline)
                                Spacer(minLength: 0)
                                Image(systemName: "chevron.forward")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(MobileTheme.muted)
                                    .accessibilityHidden(true)
                            }
                            .padding(10)
                            .frame(minHeight: 52)
                            .background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 13))
                            .contentShape(.rect)
                        }
                        .buttonStyle(AedrovaPressStyle())
                        .accessibilityHint(goal.detail)
                    }
                    Button("Skip for now") { select(.skipped) }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(MobileTheme.link)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .frame(maxWidth: 440)
                .padding(24)
                .frame(maxWidth: .infinity, minHeight: geometry.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .aedrovaScreen()
    }
}

struct FirstWorkspaceGuide: View {
    let goal: MobileOnboardingGoal
    let close: () -> Void
    let next: () -> Void
    @State private var showingExample = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Getting started").font(.headline).accessibilityAddTraits(.isHeader)
                    Text(goal.detail).font(.footnote).foregroundStyle(MobileTheme.secondary)
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.footnote.weight(.semibold))
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss workspace guide")
            }
            if goal == .explore {
                Button(showingExample ? "Hide sample" : "See a sample") { showingExample.toggle() }
                    .buttonStyle(AedrovaTextAction())
                if showingExample {
                    Text("Example only · The team agreed to add an invite step. The open question is who can send invites.")
                        .font(.footnote)
                        .foregroundStyle(MobileTheme.secondary)
                }
            } else {
                Button(goal == .catchUp ? "Search workspace" : "Open sidebar", action: next)
                    .buttonStyle(AedrovaTextAction())
            }
        }
        .padding(12)
        .frame(maxWidth: 540, alignment: .leading)
        .background(MobileTheme.canvas, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
        .frame(maxWidth: .infinity)
        .background(MobileTheme.surface)
    }
}
