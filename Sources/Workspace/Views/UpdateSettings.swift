import SwiftUI

/// ⌘, → Updates. Which version this copy is, what the latest release on GitHub
/// is, and the two switches deciding how much of the swap happens on its own.
struct UpdateSettings: View {
    /// Read straight from the shared updater: `@Observable` tracks whatever
    /// this body touches, so no copy of its state has to be kept here.
    private var updater: AppUpdater { .shared }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    versionRow
                    status
                    actions
                } header: {
                    Text("Version")
                } footer: {
                    Text("Releases are read straight from GitHub over HTTPS. No `gh`, no account, nothing to install — a release asset is a public URL.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                Section {
                    Toggle(
                        "Check for updates automatically",
                        isOn: Binding(
                            get: { updater.checksAutomatically },
                            set: { updater.checksAutomatically = $0 }
                        )
                    )
                    .pointerCursor()
                    Toggle(
                        "Download and unpack them in the background",
                        isOn: Binding(
                            get: { updater.installsAutomatically },
                            set: { updater.installsAutomatically = $0 }
                        )
                    )
                    .disabled(!updater.checksAutomatically)
                    .pointerCursor(updater.checksAutomatically)
                } header: {
                    Text("Automatic")
                } footer: {
                    Text("Checked every six hours. The last step is always a button: replacing the app means restarting it, and that closes whatever you are in the middle of.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                if let release = updater.pending, !release.notes.isEmpty {
                    Section {
                        ScrollView {
                            MarkdownText(text: release.notes)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 4)
                        }
                        .frame(maxHeight: 160)
                    } header: {
                        Text(release.title)
                    }
                }
            }
            .formStyle(.grouped)

            Divider()
            footer
        }
        // A first look at the tab is a good moment to ask, but only when
        // nothing has been asked yet this run.
        .task {
            if updater.stage == .idle { updater.check() }
        }
    }

    private var versionRow: some View {
        LabeledContent("This copy") {
            HStack(spacing: 7) {
                Text(updater.current.text)
                    .monospacedDigit()
                if case .upToDate = updater.stage {
                    Pill(text: "latest", color: .green)
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch updater.stage {
        case .idle:
            EmptyView()

        case .checking:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking GitHub…")
                    .foregroundStyle(.secondary)
            }

        case .upToDate:
            Text("Nothing newer has been released.")
                .foregroundStyle(.secondary)

        case .available(let release):
            line(
                "Workspace \(release.version.text) is out — \(release.size.formatted(.byteCount(style: .file)))\(published(release)).",
                symbol: "arrow.down.circle",
                color: .blue
            )

        case .downloading(let release, let fraction):
            VStack(alignment: .leading, spacing: 6) {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                // The size as well as the percentage: a big release moves the
                // bar slowly, and knowing it is 40 MB says the wait is the
                // download rather than something stuck.
                Text("Downloading \(release.version.text) — \(Int(fraction * 100))% of \(release.size.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

        case .ready(let release):
            line(
                "Workspace \(release.version.text) is unpacked and waiting for a relaunch.",
                symbol: "checkmark.circle",
                color: .green
            )

        case .failed(let reason):
            line(reason, symbol: "exclamationmark.triangle", color: .orange)
        }
    }

    private func line(_ text: String, symbol: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: symbol)
                .foregroundStyle(color)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private func published(_ release: AppRelease) -> String {
        guard let published = release.published else { return "" }
        return ", \(published.formatted(date: .abbreviated, time: .omitted))"
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 8) {
            switch updater.stage {
            case .available(let release):
                if updater.canInstall {
                    Button("Download \(release.version.text)") { updater.download() }
                        .buttonStyle(.borderedProminent)
                        .pointerCursor()
                } else {
                    // A copy running from a disk image, or from a folder this
                    // user cannot write to: the swap is not ours to make.
                    Text("Workspace cannot replace itself where it is — move it to Applications first.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Link("Release Notes", destination: release.page)
                    .font(.caption)
                    .pointerCursor()

            case .ready:
                Button("Relaunch and Install") { updater.installAndRelaunch() }
                    .buttonStyle(.borderedProminent)
                    .pointerCursor()

            case .downloading:
                EmptyView()

            default:
                EmptyView()
            }

            Spacer()

            if !updater.isBusy {
                Button("Check Now") { updater.check() }
                    .pointerCursor()
            }
        }
    }

    /// The bundle an update would replace — worth naming, because there is
    /// usually more than one copy of an app on a developer's Mac.
    private var footer: some View {
        HStack(spacing: 8) {
            Text("Updates replace \(updater.installLocation.path)")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let checked = updater.lastChecked {
                Text("Checked \(checked.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// The one thing an update ever interrupts anybody with: the window's own
/// notice that a new version is unpacked and only needs a restart.
struct UpdateBanner: View {
    private var updater: AppUpdater { .shared }
    /// Put away for this run. The gear in the sidebar keeps its badge, so the
    /// update is never actually lost.
    @State private var dismissedVersion: String?

    /// The release this banner is for, or nothing at all. Pulled out of the body
    /// because the transition below needs a transaction, and an `if` written
    /// straight into `body` has nothing above it for one to sit on — which is
    /// why the notice used to appear and go without playing either.
    private var announced: AppRelease? {
        guard case .ready(let release) = updater.stage,
              dismissedVersion != release.version.text
        else { return nil }
        return release
    }

    var body: some View {
        Group {
            if let release = announced {
                banner(release)
            }
        }
        .animation(ViewerMotion.listChange, value: announced?.version.text)
    }

    private func banner(_ release: AppRelease) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle.fill")
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 1) {
                Text("Workspace \(release.version.text) is ready")
                    .font(.callout.weight(.medium))
                Text("Restarting takes a moment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("Relaunch") { updater.installAndRelaunch() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .pointerCursor()
            Button {
                dismissedVersion = release.version.text
            } label: {
                Image(systemName: "xmark")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Later — the gear in the sidebar keeps it")
            .pointerCursor()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: .rect(cornerRadius: 10, style: .continuous))
        .shadow(radius: 6, y: 2)
        .padding(16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
