import AuthenticationServices
import SwiftUI
import UIKit

@main
struct AedrovaApp: App {
    @State private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let user = store.user {
                    MobileProfileGate(store: store) {
                        WorkspaceList(store: store, user: user)
                    }
                    .id(user)
                } else {
                    SignInView(store: store)
                }
            }
            .tint(MobileTheme.accent)
            .background {
                if store.user != nil { WorkspacePrivacyCover() }
            }
        }
    }
}

private struct WorkspacePrivacyCover: UIViewRepresentable {
    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ view: Anchor, context: Context) {}

    static func dismantleUIView(_ view: Anchor, coordinator: ()) {
        view.stopCovering()
    }

    final class Anchor: UIView {
        private var cover: UIView?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            stopCovering()
            guard let scene = window?.windowScene else { return }
            let notifications = NotificationCenter.default
            notifications.addObserver(self, selector: #selector(showCover),
                                      name: UIScene.willDeactivateNotification, object: scene)
            notifications.addObserver(self, selector: #selector(hideCover),
                                      name: UIScene.didActivateNotification, object: scene)
            if scene.activationState != .foregroundActive { showCover() }
        }

        func stopCovering() {
            NotificationCenter.default.removeObserver(self)
            hideCover()
        }

        @objc private func showCover() {
            guard cover == nil, let window else { return }
            let shield = UIView(frame: window.bounds)
            shield.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            shield.backgroundColor = .systemBackground
            shield.accessibilityViewIsModal = true
            let logo = UIImageView(image: UIImage(named: "Brand"))
            logo.contentMode = .scaleAspectFit
            logo.translatesAutoresizingMaskIntoConstraints = false
            shield.addSubview(logo)
            NSLayoutConstraint.activate([
                logo.widthAnchor.constraint(equalToConstant: 52),
                logo.heightAnchor.constraint(equalTo: logo.widthAnchor),
                logo.centerXAnchor.constraint(equalTo: shield.centerXAnchor),
                logo.centerYAnchor.constraint(equalTo: shield.centerYAnchor)
            ])
            window.addSubview(shield)
            cover = shield
        }

        @objc private func hideCover() {
            cover?.removeFromSuperview()
            cover = nil
        }
    }
}

@MainActor @Observable
final class WorkspaceStore {
    let api: WorkspaceAPI
    private let workspacePreference: WorkspacePreference?
    @ObservationIgnored private(set) var cache = WorkspaceCache()
    var user: UUID?
    var blockedPeople: Set<UUID> = []
    var knownChatNames: [UUID: String] = [:]

    func refreshChatBlocks() async throws {
        guard let account = user, !isDemo else { return }
        let blocks = try await api.chatBlocks()
        guard user == account else { return }
        blockedPeople = Set(blocks.map(\.userId))
        for block in blocks { knownChatNames[block.userId] = block.displayName }
    }

    func setChatBlock(_ person: UUID, workspace: UUID?, name: String? = nil, blocked: Bool) async throws {
        let account = user
        try await api.setChatBlock(person, workspace: workspace, blocked: blocked)
        guard let account, user == account else { return }
        if let name { knownChatNames[person] = name }
        if blocked { blockedPeople.insert(person) }
        else { blockedPeople.remove(person) }
    }
    var notice: String?
    var signingIn = false
    var isDemo = false
    var onboardingGoals: [UUID: MobileOnboardingGoal] = [:]
    var composerDrafts: [ChatScope: ChatView.ComposerDraft] = [:]
    var activeSends: Set<ChatScope> = []
    var failedSends: [ChatScope: ChatView.FailedSend] = [:]
    var outgoingMessages: [ChatScope: [UUID: ChatView.Row]] = [:]
    @ObservationIgnored private var profilePhotos: [String: UIImage] = [:]
    var demoMessages: [UUID: [ChatView.Row]] = [:]
    var demoConversations = Demo.conversations

    init(configuration: WorkspaceAPI.Configuration? = .current(), preferences: UserDefaults = .standard) {
        api = WorkspaceAPI(configuration: configuration)
        workspacePreference = configuration.map {
            WorkspacePreference(origin: $0.url, defaults: preferences)
        }
    }

    func resumeWorkspace(in available: [Workspace], for account: UUID) -> Workspace? {
        guard !isDemo, user == account else { return nil }
        return workspacePreference?.restore(available: available, account: account)
    }

    func rememberWorkspace(_ workspace: Workspace, for account: UUID) {
        guard !isDemo, user == account else { return }
        workspacePreference?.save(workspace, account: account)
    }

    func needsOnboarding(_ workspace: Workspace, for account: UUID) -> Bool {
        guard user == account else { return false }
        return isDemo || workspacePreference?.hasOnboarded(workspace, account: account) == false
    }

    func finishOnboarding(_ workspace: Workspace, goal: MobileOnboardingGoal, for account: UUID) {
        guard user == account else { return }
        onboardingGoals[workspace.id] = goal
        if !isDemo { workspacePreference?.markOnboarded(workspace, account: account) }
    }

    func profilePhoto(_ path: String) async -> UIImage? {
        if let cached = profilePhotos[path] { return cached }
        let account = user
        guard let data = try? await api.profilePhoto(path: path), user == account,
              !Task.isCancelled, let image = UIImage(data: data) else { return nil }
        if profilePhotos.count >= 64, let oldest = profilePhotos.keys.first { profilePhotos.removeValue(forKey: oldest) }
        profilePhotos[path] = image
        return image
    }

    func signIn(_ provider: String, using browser: WebAuthenticationSession) async {
        guard !signingIn else { return }
        signingIn = true
        notice = nil
        defer { signingIn = false }
        do {
            let request = try await api.authorization(provider: provider)
            let callback = try await browser.authenticate(using: request.url,
                                                          callbackURLScheme: WorkspaceAPI.callback.scheme!)
            user = try await api.exchange(callback, verifier: request.verifier, provider: provider)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch let error as WorkspaceError {
            notice = error.message
        } catch {
            notice = "Couldn’t finish signing in. Try again."
        }
    }

    func signOut() async {
        blockedPeople.removeAll()
        knownChatNames.removeAll()
        user = nil
        cache = WorkspaceCache()
        onboardingGoals.removeAll()
        composerDrafts.removeAll()
        activeSends.removeAll()
        failedSends.removeAll()
        outgoingMessages.removeAll()
        profilePhotos.removeAll()
        notice = nil
        if isDemo {
            isDemo = false
            demoMessages = [:]
            demoConversations = Demo.conversations
            return
        }
        signingIn = true
        defer { signingIn = false }
        do {
            try await api.signOut()
        } catch {
            notice = "Signed out here. Aedrova couldn’t reach the server to end this session."
        }
    }

    #if DEBUG
    func openDemo() {
        isDemo = true
        user = Demo.user
    }
    #endif
}

private struct SignInView: View {
    @Environment(\.webAuthenticationSession) private var browser
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var brandVisible = false
    let store: WorkspaceStore

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                loginContent
                    .frame(minHeight: geometry.size.height)
                    .frame(maxWidth: .infinity)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .aedrovaScreen()
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                brandVisible = true
            }
        }
    }

    private var loginContent: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)
            VStack(spacing: 0) {
                Image("AedrovaMark")
                    .resizable().scaledToFit()
                    .frame(width: 80, height: 80)
                    .accessibilityHidden(true)
                Image("AedrovaWordmark")
                    .resizable().scaledToFit()
                    .foregroundStyle(.primary)
                    .frame(width: 214)
                    .padding(.top, 16)
                    .accessibilityLabel("Aedrova")
                    .accessibilityAddTraits(.isHeader)
                Text("Your team, plus Agents")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .padding(.top, 6)
            }
            .opacity(brandVisible || reduceMotion ? 1 : 0)
            Spacer(minLength: 28)
            VStack(spacing: 12) {
                Button { Task { await store.signIn("google", using: browser) } } label: {
                    HStack(spacing: 10) {
                        Image("GoogleSignIn")
                            .resizable().scaledToFit()
                            .frame(width: 17, height: 17)
                            .frame(width: 24, height: 24)
                            .background(.white, in: RoundedRectangle(cornerRadius: 5))
                            .accessibilityHidden(true)
                        Text("Continue with Google")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button { Task { await store.signIn("apple", using: browser) } } label: {
                    Label("Sign in with Apple", systemImage: "apple.logo").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.primary)
                if store.signingIn { ProgressView().accessibilityLabel("Signing in") }
                if let notice = store.notice {
                    Text(notice).font(.footnote).foregroundStyle(.secondary)
                }
            }
            .controlSize(.large)
            .disabled(store.signingIn)
            #if DEBUG
            Button("Open local demo", action: store.openDemo)
                .font(.footnote).padding(.top, 20)
                .disabled(store.signingIn)
            #endif
        }
        .frame(maxWidth: 400)
        .padding(28)
        .safeAreaPadding(.bottom, 12)
    }
}

private struct WorkspaceList: View {
    let store: WorkspaceStore
    let user: UUID
    @State private var workspaces: [Workspace] = []
    @State private var people: [Person] = []
    @State private var loaded = false
    @State private var loading = false
    @State private var didAttemptResume = false
    @State private var openedWorkspace: Workspace?
    @State private var showingAccount = false
    @State private var error: String?
    @State private var setup: WorkspaceSetup?
    @State private var justOnboarded: UUID?
    @State private var onboardingWorkspace: Workspace?
    @State private var onboardingSelection: (Workspace, MobileOnboardingGoal)?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                Text("Your workspaces")
                    .font(.largeTitle.weight(.semibold))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 6)

                if let error {
                    AedrovaState(title: "Couldn’t load workspaces", detail: error, symbol: "wifi.slash")
                    Button("Try again") { Task { await load() } }
                        .buttonStyle(AedrovaTextAction())
                } else if !loaded {
                    ProgressView("Loading workspaces").padding(.vertical, 14)
                } else if workspaces.isEmpty {
                    WorkspaceSetupEntry { setup = $0 }
                }

                ForEach(workspaces) { workspace in
                    Button {
                        openWorkspace(workspace)
                    } label: {
                        HStack(spacing: 14) {
                            AedrovaInitials(name: workspace.name, size: 46, emphasized: true)
                            Text(workspace.name)
                                .font(.headline)
                                .foregroundStyle(MobileTheme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .multilineTextAlignment(.leading)
                            Image(systemName: "arrow.right")
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(MobileTheme.link)
                                .accessibilityHidden(true)
                        }
                        .padding(14)
                        .frame(minHeight: 74)
                        .background(MobileTheme.surface, in: RoundedRectangle(cornerRadius: 16))
                        .contentShape(.rect)
                    }
                    .buttonStyle(AedrovaPressStyle())
                    .accessibilityHint("Opens this workspace")
                }
            }
            .frame(maxWidth: 540)
            .padding(.horizontal, 20)
            .padding(.vertical, 22)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .navigationTitle("Workspaces")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) { AedrovaLockup() }
            ToolbarItemGroup(placement: .topBarTrailing) {
                if loaded && error == nil && !workspaces.isEmpty && !store.isDemo {
                    Button { setup = .choose } label: {
                        Image(systemName: "plus").frame(minWidth: 44, minHeight: 44)
                    }
                    .accessibilityLabel("Create or join a workspace")
                }
                Button { showingAccount = true } label: {
                    Image(systemName: "person.crop.circle")
                        .foregroundStyle(MobileTheme.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityLabel("Account")
            }
        }
        .aedrovaScreen()
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $showingAccount) { AccountSettingsSheet(store: store) }
        .sheet(item: $setup, onDismiss: openOnboardedWorkspace) { step in
            WorkspaceSetupSheet(api: store.api, knownWorkspaces: Set(workspaces.map(\.id)),
                                didLoad: { workspaces = $0; loaded = true; error = nil },
                                didOpen: { justOnboarded = $0.id }, step: step)
        }
        .sheet(item: $onboardingWorkspace, onDismiss: finishGoalSelection) { workspace in
            MobileGoalSheet(workspace: workspace) { goal in
                onboardingSelection = (workspace, goal)
                onboardingWorkspace = nil
            }
            .interactiveDismissDisabled()
        }
        .navigationDestination(item: $openedWorkspace) { workspace in
            ConversationList(store: store, user: user, workspace: workspace,
                             people: workspacePeople(workspace),
                             onboardingGoal: store.onboardingGoals[workspace.id],
                             didFinishGuide: { store.onboardingGoals[workspace.id] = nil })
        }
    }

    private func openOnboardedWorkspace() {
        guard store.user == user, let workspaceID = justOnboarded,
              let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
        justOnboarded = nil
        openWorkspace(workspace)
        Task {
            if let members = try? await store.api.directory(), store.user == user {
                people = members
            }
        }
    }

    private func openWorkspace(_ workspace: Workspace) {
        guard store.user == user else { return }
        didAttemptResume = true
        if store.needsOnboarding(workspace, for: user) {
            onboardingWorkspace = workspace
        } else {
            enterWorkspace(workspace)
        }
    }

    private func finishGoalSelection() {
        guard let (workspace, goal) = onboardingSelection else { return }
        onboardingSelection = nil
        guard store.user == user, workspaces.contains(where: { $0.id == workspace.id }) else { return }
        store.finishOnboarding(workspace, goal: goal, for: user)
        enterWorkspace(workspace)
    }

    private func enterWorkspace(_ workspace: Workspace) {
        store.rememberWorkspace(workspace, for: user)
        openedWorkspace = workspace
    }

    private func workspacePeople(_ workspace: Workspace) -> [UUID: String] {
        Dictionary(people.lazy.filter { $0.workspaceId == workspace.id }
            .map { ($0.userId, $0.displayName) }, uniquingKeysWith: { first, _ in first })
    }

    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        do {
            if store.isDemo {
                workspaces = [Demo.workspace]
                people = Demo.people
            } else {
                async let workspaceRows = store.api.workspaces()
                async let directory = store.api.directory()
                let rows = try await workspaceRows
                try Task.checkCancellation()
                guard store.user == user else { return }
                workspaces = rows
                loaded = true
                error = nil
                if !didAttemptResume {
                    didAttemptResume = true
                    openedWorkspace = store.resumeWorkspace(in: rows, for: user)
                }
                if let members = try? await directory, !Task.isCancelled, store.user == user {
                    people = members
                }
            }
            error = nil
            loaded = true
        } catch is CancellationError {
        } catch let failure {
            guard !Task.isCancelled, store.user == user else { return }
            workspaces = []
            people = []
            error = message(for: failure)
        }
    }
}

func message(for error: Error) -> String {
    (error as? WorkspaceError)?.message ?? "Couldn’t reach Aedrova. Try again."
}
