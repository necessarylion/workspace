import AppKit
import SwiftUI

/// The pull request's own side panel, down the right of the Details tab: who is
/// reviewing it, and what CI made of it.
///
/// Both used to be somewhere else — the reviewers as a row above the
/// description, the builds as a tab of their own — and neither was worth a
/// whole window. Together in a column they are read at a glance beside the
/// conversation, and the Builds tab is gone. It stops at Details on purpose:
/// the Diff and Commits tabs want every pixel of width they can get.
///
/// It does not fold away itself — there is no switch for it. Details is a page
/// two columns wide, and half of what the tab is for would go with the panel.
/// The seam beside it drags, which is the one thing worth changing about it.
struct PullRequestSidebar: View {
    @Environment(WorkspaceStore.self) private var store
    let item: ViewerItem
    let pr: PullRequest
    let project: Project
    /// Whether anything can still be asked of this pull request — a merged or
    /// closed one has nobody left to add as a reviewer.
    let isOpen: Bool
    let onAddReviewers: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                reviewers
                Divider()
                builds
            }
            .padding(11)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(nsColor: AppColors.viewerBackground))
        // Reading the runs, and going on reading them, belongs to the view
        // above this one: the badge in its summary bar shows them on the tabs
        // where this panel is not drawn at all. See `watchBuilds`.
    }

    // MARK: - Reviewers

    private var reviewers: some View {
        // Sorted once for the pass: the header's summary and the rows under it
        // are the same list, and `byStanding` sorts each time it is asked.
        let ordered = item.reviewers.byStanding
        return VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "Reviewers",
                symbol: "person.2",
                detail: ordered.isEmpty ? nil : item.reviewers.approvalSummary,
                isLoading: item.isLoadingReviewers
            ) {
                EmptyView()
            }

            // Who is reviewing changes when somebody reviews or the sheet asks
            // more people — a handful of times an hour at the very most, and
            // never on a timer. So the list is one of the few here worth
            // animating, keyed to who is on it rather than to what they said.
            Group {
                if ordered.isEmpty {
                    emptyNote(item.reviewersError
                        ?? (item.isLoadingReviewers
                            ? "Reading who is reviewing…"
                            : "Nobody is reviewing #\(pr.number) yet."))
                        .transition(ViewerMotion.contentArrival)
                } else {
                    ForEach(ordered) { reviewer in
                        reviewerRow(reviewer)
                            .transition(.opacity)
                    }
                }
            }
            .animation(ViewerMotion.listChange, value: item.reviewers.map(\.id))

            // Nothing to ask of a pull request that has already ended. The
            // button sits under the list rather than in the header: it is the
            // one thing done to this section, and a card the width of the rows
            // it adds to is both easier to hit and easier to find than a glyph.
            if isOpen {
                AddReviewersCard(number: pr.number, action: onAddReviewers)
            }
        }
    }

    private func reviewerRow(_ reviewer: PullRequestReviewer) -> some View {
        HStack(spacing: 8) {
            ReviewerFace(reviewer: reviewer, size: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(reviewer.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(reviewer.state.title)
                    .font(.caption2)
                    .foregroundStyle(reviewer.state.color)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.22), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: - Builds

    /// The CI runs on the pull request's head commit. Failures sort to the top
    /// in the loader: one red job at the end of a long green list is the one
    /// thing here nobody should have to scroll for.
    private var builds: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader(
                "Builds",
                symbol: "hammer",
                detail: item.builds.isEmpty ? nil : buildSummary,
                isLoading: item.isLoadingBuilds
            ) {
                headerButton("arrow.clockwise", help: "Read the builds again") {
                    Task { await store.loadBuilds(item, project: project, pr: pr) }
                }
                .disabled(item.isLoadingBuilds)
            }

            // The note gives way to the first runs, and that is the whole of the
            // motion here. The **rows** are deliberately left out of it: the
            // list is read again every ten seconds and the loader sorts
            // failures to the top, so they genuinely reorder on a timer — an
            // animated list would have this panel shuffling by itself while it
            // is being read. A running job already says it is moving, in the
            // pulse on its own glyph.
            Group {
                if item.builds.isEmpty {
                    emptyNote(item.buildsError
                        ?? (item.isLoadingBuilds
                            ? "Reading builds…"
                            : "Nothing has run against this pull request's head commit on \(pr.host.displayName)."))
                        .transition(ViewerMotion.contentArrival)
                    if item.buildsError != nil, let url = pr.url {
                        Button {
                            NSWorkspace.shared.open(url)
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                                .font(.caption)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .pointerCursor()
                        .transition(ViewerMotion.contentArrival)
                    }
                } else {
                    ForEach(item.builds) { BuildRow(build: $0) }
                }
            }
            .animation(ViewerMotion.contentChange, value: item.builds.isEmpty)
        }
    }

    /// "3 passed · 1 failed" — how the runs stand, without reading the list.
    private var buildSummary: String {
        var parts: [String] = []
        for state in [PullRequestBuild.State.failed, .running, .pending, .passed] {
            let count = item.builds.lazy.filter { $0.state == state }.count
            if count > 0 { parts.append("\(count) \(state.title.lowercased())") }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - Shared pieces

    @ViewBuilder
    private func sectionHeader<Trailing: View>(
        _ title: String,
        symbol: String,
        detail: String?,
        isLoading: Bool,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if isLoading {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                Spacer(minLength: 4)
                trailing()
            }
            if let detail {
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
            }
        }
    }

    private func headerButton(
        _ symbol: String,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help(help)
        .pointerCursor()
    }

    private func emptyNote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Adding reviewers

/// The way to ask more people to review, drawn as a card the width of the
/// reviewer rows it adds to and sitting directly under them.
///
/// It was a header glyph before, which put the section's only action in its
/// smallest target. Dashed rather than filled, so it reads as the empty slot
/// at the end of the list instead of as another reviewer.
struct AddReviewersCard: View {
    let number: Int
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "person.badge.plus")
                    .font(.callout)
                    .frame(width: 20)
                Text("Add Reviewers")
                    .font(.callout)
                Spacer(minLength: 0)
            }
            .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                .quaternary.opacity(isHovering ? 0.22 : 0),
                in: RoundedRectangle(cornerRadius: 7)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(
                        .quaternary,
                        style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .help("Ask other people to review #\(number)")
    }
}

// MARK: - One build

/// One CI run: how it ended, what it is called, and the way to its log.
///
/// The whole row opens the log on the host — the arrow at its end is a sign of
/// where it goes, not the only thing that goes there. A build the host gave no
/// page for stays a plain row, since there would be nothing to open.
struct BuildRow: View {
    let build: PullRequestBuild

    @State private var isHovering = false

    var body: some View {
        if let url = build.url {
            Button {
                NSWorkspace.shared.open(url)
            } label: {
                content
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .pointerCursor()
            .help("Open \(build.name) on \(build.url?.host() ?? "the host")")
        } else {
            content
        }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: build.state.symbol)
                .foregroundStyle(build.state.color)
                .font(.callout)
                // Steady width, so the names line up down a mixed list rather
                // than shifting with each glyph.
                .frame(width: 16)
                // A running job says so by moving; the rest are still.
                .symbolEffect(.pulse, isActive: build.state == .running)

            VStack(alignment: .leading, spacing: 2) {
                Text(build.name)
                    .font(.callout)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                // Two short lines rather than one long one: the panel is a
                // column, and everything after the verdict was falling off the
                // end of it.
                HStack(spacing: 6) {
                    Text(build.state.title)
                        .foregroundStyle(build.state.color)
                    if let duration = build.durationLabel {
                        Text(duration).foregroundStyle(.tertiary)
                    }
                    if let started = build.startedAt {
                        Text(started.formatted(.relative(presentation: .named)))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                if let detail = build.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if build.url != nil {
                Image(systemName: "arrow.up.forward.app")
                    .font(.caption)
                    .foregroundStyle(isHovering ? .secondary : .tertiary)
            }
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            .quaternary.opacity(isHovering ? 0.34 : 0.22),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

/// The colour a build's outcome is drawn in, the same in the row and in the
/// section's summary line.
extension PullRequestBuild.State {
    var color: Color {
        switch self {
        case .passed: .green
        case .failed: .red
        case .running: .blue
        case .pending: .orange
        case .cancelled, .skipped, .unknown: .secondary
        }
    }
}
