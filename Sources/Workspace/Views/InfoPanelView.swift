import AppKit
import SwiftUI

/// The Info tab: where the project lives, what it is connected to, what it is
/// running, and the ways out of this app into another tool.
struct InfoPanelView: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                openInSection
                locationSection
                repositorySection
                portsSection
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .task(id: project.id) {
            await project.refreshPorts()
        }
    }

    // MARK: - Open in

    private var openInSection: some View {
        InfoSection(title: "Open In", symbol: "arrow.up.forward.app") {
            HStack(spacing: 6) {
                Button {
                    store.openExternally(project, using: .vscode)
                } label: {
                    Label("VS Code", systemImage: ExternalTool.vscode.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                Button {
                    store.openTerminal(in: project)
                } label: {
                    Label("Terminal", systemImage: "terminal")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
        }
    }

    // MARK: - Location

    private var locationSection: some View {
        InfoSection(title: "Folder", symbol: "folder") {
            HStack(alignment: .top, spacing: 6) {
                Text(project.url.path)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(project.url.path, forType: .string)
                    store.statusMessage = "Path copied"
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .help("Copy path")
            }
        }
    }

    // MARK: - Repository

    private var repositorySection: some View {
        InfoSection(title: "Repository", symbol: project.host.symbol) {
            if let remote = project.remote {
                InfoRow(label: "Host", value: remote.kind.displayName)
                InfoRow(label: "Repo", value: remote.fullName)
                if let url = remote.webURL {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Label("Open on \(remote.kind.displayName)", systemImage: "safari")
                    }
                    .controlSize(.small)
                    .buttonStyle(.bordered)
                    .padding(.top, 2)
                }
            } else {
                Text("No git remote configured.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let status = project.gitStatus {
                Divider().padding(.vertical, 2)
                InfoRow(label: "Branch", value: status.branch)
                if status.ahead > 0 || status.behind > 0 {
                    InfoRow(label: "Tracking", value: "↑\(status.ahead) ↓\(status.behind)")
                }
                InfoRow(
                    label: "Changes",
                    value: status.changes.isEmpty ? "clean" : "\(status.changes.count) files"
                )
                InfoRow(label: "Open PRs", value: "\(project.pullRequests.count)")
            }

            if let commit = project.headCommit {
                Divider().padding(.vertical, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(commit.subject)
                        .font(.caption)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        Text(commit.hash).font(.system(.caption2, design: .monospaced))
                        Text(commit.author)
                        if let date = commit.date {
                            Text(date.formatted(.relative(presentation: .named)))
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Ports

    private var portsSection: some View {
        InfoSection(title: "Ports", symbol: "network") {
            if project.isScanningPorts && project.ports.isEmpty {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Scanning…").font(.caption).foregroundStyle(.secondary)
                }
            } else if project.ports.isEmpty {
                Text("Nothing listening from this folder.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(project.ports) { port in
                    HStack(spacing: 8) {
                        Circle().fill(.green).frame(width: 7, height: 7)
                        Text("\(port.port)")
                            .font(.system(.callout, design: .monospaced))
                        Text(port.processName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer()
                        if let url = port.localURL {
                            Button {
                                NSWorkspace.shared.open(url)
                            } label: {
                                Image(systemName: "safari")
                            }
                            .buttonStyle(.plain)
                            .help("Open http://localhost:\(port.port)")
                        }
                    }
                }
            }

            Button {
                Task { await project.refreshPorts() }
            } label: {
                Label("Rescan", systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .padding(.top, 2)
        }
    }

    // MARK: - Language servers

    private var languageServerSection: some View {
        InfoSection(title: "Language Servers", symbol: "wand.and.stars") {
            let services = LanguageServerRegistry.shared.services(inside: project.url)
            if services.isEmpty {
                Text("None started yet — open a source file.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(services, id: \.definition.executable) { service in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(service.status.isHealthy ? Color.green : Color.orange)
                            .frame(width: 7, height: 7)
                        Text(service.definition.displayName)
                            .font(.system(.caption, design: .monospaced))
                        Spacer()
                        Text(service.status.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }
}

// MARK: - Building blocks

struct InfoSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(title, systemImage: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 9))
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}
