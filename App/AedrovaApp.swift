import AuthenticationServices
import SwiftUI

@main
struct AedrovaApp: App {
    @State private var store = WorkspaceStore()

    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let user = store.user {
                    WorkspaceList(store: store, user: user)
                } else {
                    SignInView(store: store)
                }
            }
            .tint(Color(red: 0, green: 0.42, blue: 0.88))
        }
    }
}

@MainActor @Observable
final class WorkspaceStore {
    let api = WorkspaceAPI()
    var user: UUID?
    var notice: String?
    var signingIn = false
    var isDemo = false
    var demoMessages: [UUID: [ChatView.Row]] = [:]
    var demoConversations = Demo.conversations

    func signIn(_ provider: String, using browser: WebAuthenticationSession) async {
        guard !signingIn else { return }
        signingIn = true
        notice = nil
        defer { signingIn = false }
        do {
            let request = try await api.authorization(provider: provider)
            let callback = try await browser.authenticate(using: request.url,
                                                          callbackURLScheme: WorkspaceAPI.callback.scheme!)
            user = try await api.exchange(callback, verifier: request.verifier)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            notice = "Couldn’t finish signing in. Try again."
        }
    }

    func signOut() async {
        user = nil
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
    let store: WorkspaceStore

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image("Brand")
                .resizable().scaledToFit()
                .frame(width: 80, height: 80)
                .accessibilityHidden(true)
            Text("aedrova").font(.system(size: 53, weight: .semibold))
                .padding(.top, 16)
                .accessibilityAddTraits(.isHeader)
            Text("Your team, plus Agents")
                .font(.title3)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
            Spacer()
            VStack(spacing: 12) {
                Button { Task { await store.signIn("google", using: browser) } } label: {
                    Text("Continue with Google").frame(maxWidth: .infinity)
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
    @State private var error: String?

    var body: some View {
        List(workspaces) { workspace in
            NavigationLink {
                ConversationList(store: store, user: user, workspace: workspace,
                                 people: Dictionary(people.filter { $0.workspaceId == workspace.id }
                                    .map { ($0.userId, $0.displayName) }, uniquingKeysWith: { first, _ in first }))
            } label: {
                Label(workspace.name, systemImage: "square.grid.2x2")
            }
        }
        .navigationTitle("Workspaces")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.signOut() } } label: {
                    Image(systemName: "rectangle.portrait.and.arrow.right")
                }
                .accessibilityLabel("Sign out")
            }
        }
        .overlay {
            if workspaces.isEmpty {
                if let error {
                    ContentUnavailableView {
                        Label("Workspaces unavailable", systemImage: "wifi.slash")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else if loaded {
                    ContentUnavailableView("No workspaces yet", systemImage: "square.grid.2x2",
                                           description: Text("Ask a teammate to invite you."))
                } else {
                    ProgressView("Loading workspaces")
                }
            }
        }
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        do {
            if store.isDemo {
                workspaces = [Demo.workspace]
                people = Demo.people
            } else {
                async let workspaceRows = store.api.workspaces()
                async let directory = store.api.directory()
                let (rows, members) = try await (workspaceRows, directory)
                try Task.checkCancellation()
                workspaces = rows
                people = members
            }
            error = nil
            loaded = true
        } catch is CancellationError {
        } catch let failure {
            workspaces = []
            people = []
            error = message(for: failure)
        }
    }
}

func message(for error: Error) -> String {
    (error as? WorkspaceError)?.message ?? "Couldn’t reach Aedrova. Try again."
}
