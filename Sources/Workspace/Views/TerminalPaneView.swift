import SwiftUI

/// Hosts a running `GhosttySurfaceView`. The view instance lives on the
/// session, so navigating away and back never restarts the shell.
struct TerminalPaneView: NSViewRepresentable {
    let session: TerminalSession

    func makeNSView(context: Context) -> GhosttySurfaceView {
        let view = session.view
        // Focus the shell as soon as it is on screen.
        DispatchQueue.main.async {
            view.window?.makeFirstResponder(view)
        }
        return view
    }

    func updateNSView(_ nsView: GhosttySurfaceView, context: Context) {
        // Nothing to sync: the terminal owns its own state.
    }
}

/// The terminal item: a tab bar over the selected shell. Only the terminal has
/// tabs — the rest of the viewer still shows one item at a time.
struct TerminalContainerView: View {
    @Environment(WorkspaceStore.self) private var store
    let item: ViewerItem

    var body: some View {
        VStack(spacing: 0) {
            tabBar
            Divider()
            if let session = item.selectedTerminal {
                TerminalTabView(session: session)
                    // A new representable per session: the NSView belongs to
                    // the session and cannot be swapped in updateNSView.
                    .id(session.id)
            } else {
                ContentUnavailableView("Terminal ended", systemImage: "terminal")
            }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 4) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(item.terminals) { session in
                        TerminalTabButton(
                            session: session,
                            isSelected: session.id == item.selectedTerminal?.id,
                            select: { item.selectedTerminalID = session.id },
                            close: { store.closeTerminalTab(session, in: item) }
                        )
                    }
                }
                .padding(.horizontal, 6)
            }

            Button {
                store.newTerminalTab(in: item)
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .help("New Terminal Tab (⌘T)")
        }
        .frame(height: 30)
        .background(.bar)
    }
}

/// One tab in the terminal tab bar.
private struct TerminalTabButton: View {
    let session: TerminalSession
    let isSelected: Bool
    let select: () -> Void
    let close: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "terminal")
                .font(.system(size: 10))
            Text(session.title)
                .lineLimit(1)
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering || isSelected ? 1 : 0)
            .help("Close Tab")
        }
        .font(.caption)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(
            isSelected ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear),
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}

/// The terminal with a small inset so the first line doesn't touch the edges.
struct TerminalTabView: View {
    let session: TerminalSession

    var body: some View {
        TerminalPaneView(session: session)
            .padding(.top, 10)
            .padding(.leading, 6)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
