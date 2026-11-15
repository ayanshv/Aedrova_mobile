import Foundation

struct WorkspacePreference {
    let origin: URL
    let defaults: UserDefaults

    func restore(available: [Workspace], account: UUID) -> Workspace? {
        let key = key(for: account)
        guard let value = defaults.string(forKey: key) else { return nil }
        if let workspace = available.first(where: { $0.id.uuidString == value }) {
            return workspace
        }
        defaults.removeObject(forKey: key)
        return nil
    }

    func save(_ workspace: Workspace, account: UUID) {
        defaults.set(workspace.id.uuidString, forKey: key(for: account))
    }

    func hasOnboarded(_ workspace: Workspace, account: UUID) -> Bool {
        defaults.bool(forKey: onboardingKey(workspace, account: account))
    }

    func markOnboarded(_ workspace: Workspace, account: UUID) {
        defaults.set(true, forKey: onboardingKey(workspace, account: account))
    }

    private func onboardingKey(_ workspace: Workspace, account: UUID) -> String {
        "mobileOnboarding.\(origin.host ?? origin.absoluteString).\(account.uuidString).\(workspace.id.uuidString)"
    }

    private func key(for account: UUID) -> String {
        "lastWorkspace.\(origin.host ?? origin.absoluteString).\(account.uuidString)"
    }
}
