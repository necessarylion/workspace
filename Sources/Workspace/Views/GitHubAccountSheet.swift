import SwiftUI

/// Asked once, when a GitHub repository is added and `gh` is logged in to more
/// than one account. The answer is remembered, so every later `gh` call for
/// this repository uses the same account without asking again.
struct GitHubAccountSheet: View {
    @Environment(WorkspaceStore.self) private var store
    let prompt: GitHubAccountPrompt

    @State private var selection = ""

    private var project: Project? { store.project(withID: prompt.projectID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Which GitHub account?")
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(spacing: 0) {
                ForEach(store.gitHubAccounts) { account in
                    accountRow(account)
                    if account.id != store.gitHubAccounts.last?.id {
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))

            HStack {
                Text("You can change this later from the repository's menu.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
                Button("Cancel") { store.resolveGitHubAccountPrompt(nil) }
                    .keyboardShortcut(.cancelAction)
                    .pointerCursor()
                Button("Use Account") { store.resolveGitHubAccountPrompt(selection) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(selection.isEmpty)
                    .pointerCursor(!selection.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 380)
        .onAppear { selection = prompt.suggested }
    }

    private var subtitle: String {
        guard let project else { return "Pick the account this repository belongs to." }
        let repo = project.remote?.fullName ?? project.name
        return "\(repo) will use this account for pull requests, comments and checkouts."
    }

    private func accountRow(_ account: GitHubAccount) -> some View {
        Button {
            selection = account.login
        } label: {
            HStack(spacing: 9) {
                Image(systemName: selection == account.login
                    ? "largecircle.fill.circle"
                    : "circle")
                    .foregroundStyle(selection == account.login ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                AuthorAvatar(
                    name: account.login,
                    url: AvatarURL.gitHub(login: account.login),
                    size: 20
                )
                Text(account.login)
                    .font(.callout.weight(.medium))
                if account.isActive {
                    Text("gh default")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerCursor()
    }
}

/// The "GitHub Account" submenu, shared by the sidebar's context menu and the
/// Info panel.
struct GitHubAccountMenu: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    var body: some View {
        Menu("GitHub Account") {
            if store.gitHubAccounts.isEmpty {
                Text("No accounts found — run `gh auth login`.")
            }
            ForEach(store.gitHubAccounts) { account in
                Button {
                    store.setGitHubAccount(account.login, for: project)
                } label: {
                    // A checkmark would need a Toggle; the label carries it.
                    Label(
                        account.login,
                        systemImage: project.gitHubAccount == account.login ? "checkmark" : "person"
                    )
                }
            }
            Divider()
            Button("Use gh's Default") { store.setGitHubAccount(nil, for: project) }
            Button("Reload Accounts") { Task { await store.loadGitHubAccounts(reloading: true) } }
        }
        .task { await store.loadGitHubAccounts() }
    }
}
