import AppKit
import SwiftUI

/// Right sidebar: every repository the user added, as a card.
struct ProjectsSidebar: View {
    @Environment(WorkspaceStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            header

            if store.projects.isEmpty {
                ContentUnavailableView {
                    Label("No repositories", systemImage: "folder.badge.plus")
                } description: {
                    Text("Repositories only appear here once you add their folder.")
                } actions: {
                    Button("Add Repository…") { store.promptForProjectFolder() }
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 7) {
                        ForEach(store.projects) { project in
                            ProjectCard(project: project, isSelected: project.id == store.selectedProjectID)
                                .onTapGesture { store.selectedProjectID = project.id }
                                .contextMenu { menu(project) }
                        }
                    }
                    .padding(10)
                }
            }

            Divider()
            footer
        }
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var header: some View {
        HStack {
            Text("Repositories")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            Text("\(store.projects.count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                store.promptForProjectFolder()
            } label: {
                Label("Add Repository", systemImage: "plus")
            }
            .buttonStyle(.plain)
            Spacer()
            Button {
                store.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.plain)
            .help("Refresh every repository")
            .disabled(store.projects.isEmpty)
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private func menu(_ project: Project) -> some View {
        Button("Refresh") { Task { await project.refresh() } }
        Button("Open Terminal") { store.openTerminal(in: project) }
        Divider()
        if let url = project.remote?.webURL {
            Button("Open Repository in Browser") { NSWorkspace.shared.open(url) }
        }
        Button("Reveal in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([project.url])
        }
        Divider()
        Button("Remove from Workspace") { store.removeProject(project) }
    }
}

/// One repository, summarised.
struct ProjectCard: View {
    let project: Project
    let isSelected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: project.host.symbol)
                    .foregroundStyle(project.host == .unknown ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                Text(project.name)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                Spacer()
                if project.isLoadingPullRequests {
                    ProgressView().controlSize(.mini)
                }
            }

            if let status = project.gitStatus {
                HStack(spacing: 5) {
                    Image(systemName: "arrow.triangle.branch")
                    Text(status.branch)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if status.ahead > 0 { Text("↑\(status.ahead)") }
                    if status.behind > 0 { Text("↓\(status.behind)") }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            } else {
                Text("Not a git repository")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            HStack(spacing: 5) {
                Pill(
                    text: "\(project.pullRequests.count) PR",
                    color: project.pullRequests.isEmpty ? .secondary : .accentColor
                )
                Pill(
                    text: project.changeCount == 0 ? "clean" : "\(project.changeCount) changed",
                    color: project.changeCount == 0 ? .green : .orange
                )
                if !project.ports.isEmpty {
                    Pill(text: "\(project.ports.count) port", color: .green)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(isSelected ? AnyShapeStyle(.tint.opacity(0.14)) : AnyShapeStyle(.quaternary.opacity(0.22)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear), lineWidth: 1.2)
        )
        .contentShape(Rectangle())
    }
}

struct Pill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.16), in: Capsule())
            .foregroundStyle(color)
    }
}
