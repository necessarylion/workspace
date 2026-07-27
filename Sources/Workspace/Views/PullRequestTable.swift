import AppKit
import SwiftUI

/// The widths the header and every row of the table share. Wide enough for
/// "14 hours ago" and three faces, and no wider — the space they do not take
/// goes to the titles.
private enum Column {
    static let created: CGFloat = 108
    static let activity: CGFloat = 74
    static let reviewers: CGFloat = 96
    static let builds: CGFloat = 54
    static let spacing: CGFloat = 14
    /// The margin between a row's card and the box around the table.
    static let rowInset: CGFloat = 6
    /// The padding inside a row's card, and the header's, so the column titles
    /// line up with what is under them.
    static let cardPadding: CGFloat = 12
}

/// The open pull requests, as a table rather than as a wall of cards.
///
/// A board of tiles reads one request at a time; the thing actually being done
/// here is comparing them — which has sat longest, which nobody has reviewed,
/// which is red. So every request is one row and every question is a column,
/// which is what lets the answer be found by running an eye down the page.
///
/// The four right-hand columns are deliberately narrow and fixed: they hold a
/// date, a count, a few faces and one glyph, and giving them room to breathe
/// would only take it from the titles.
struct PullRequestTable: View {
    @Environment(WorkspaceStore.self) private var store
    let project: Project

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            title
            if project.pullRequests.isEmpty {
                emptyState
            } else {
                table
            }
        }
    }

    private var title: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("Open pull requests")
                .font(.headline)
            Text("\(project.pullRequests.count)")
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)

            // The reload the navigator's PR tab used to carry. The board is the
            // only place these are listed now, so it has to live here.
            if project.isLoadingPullRequests {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await project.refreshPullRequests() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .font(.callout)
                .foregroundStyle(.secondary)
                .help("Read the pull requests again")
                .pointerCursor()
            }
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if project.isLoadingPullRequests {
            note("Reading pull requests…")
        } else if let error = project.pullRequestError {
            VStack(alignment: .leading, spacing: 6) {
                note(error)
                Button("Try Again") { Task { await project.refreshPullRequests() } }
                    .controlSize(.small)
                    .pointerCursor()
            }
        } else {
            note("Nothing is open — everything is merged.")
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// The rows are drawn as rounded cards rather than as banded stripes with
    /// rules between them: a square-cornered tint running the full width fought
    /// the rounded box around it at every corner it met. Each row now sits
    /// inside the box with a margin of its own, which is also what makes the
    /// hover read as *this row* rather than as a bar across the table.
    private var table: some View {
        VStack(spacing: 3) {
            header
            Divider().padding(.bottom, 2)
            ForEach(Array(project.pullRequests.enumerated()), id: \.element.id) { index, pr in
                PullRequestTableRow(
                    pr: pr,
                    isAlternate: index.isMultiple(of: 2) == false,
                    open: { store.openPullRequest(pr, project: project) }
                )
            }
        }
        .padding(.horizontal, Column.rowInset)
        .padding(.vertical, 8)
        .background(.quaternary.opacity(0.14), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.quaternary.opacity(0.5))
        }
    }

    /// Lined up with the row content, which is inset by the same amount inside
    /// its own card — the column titles have to sit over their columns.
    private var header: some View {
        HStack(spacing: Column.spacing) {
            columnTitle("Summary").frame(maxWidth: .infinity, alignment: .leading)
            columnTitle("Created").frame(width: Column.created, alignment: .leading)
            columnTitle("Activity").frame(width: Column.activity, alignment: .leading)
            columnTitle("Reviewers").frame(width: Column.reviewers, alignment: .leading)
            columnTitle("Builds").frame(width: Column.builds, alignment: .leading)
        }
        .padding(.horizontal, Column.cardPadding)
        .padding(.top, 3)
        .padding(.bottom, 6)
    }

    private func columnTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }
}

/// One request, across the five columns.
///
/// Split out from the table so the hover state belongs to the row rather than
/// to the list: a `@State` on the parent would redraw every row each time the
/// pointer crossed one.
struct PullRequestTableRow: View {
    let pr: PullRequest
    let isAlternate: Bool
    let open: () -> Void

    @State private var isHovering = false

    private let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)

    var body: some View {
        Button(action: open) {
            HStack(spacing: Column.spacing) {
                summary.frame(maxWidth: .infinity, alignment: .leading)
                created.frame(width: Column.created, alignment: .leading)
                activity.frame(width: Column.activity, alignment: .leading)
                reviewers.frame(width: Column.reviewers, alignment: .leading)
                builds.frame(width: Column.builds, alignment: .leading)
            }
            .padding(.horizontal, Column.cardPadding)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: shape)
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .pointerCursor()
        .help(pr.title)
        .contextMenu {
            Button("Open Pull Request", action: open)
            if let url = pr.url {
                Button("Open in Browser") { NSWorkspace.shared.open(url) }
                Button("Copy Link") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                }
            }
            Button("Copy Branch Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(pr.sourceBranch, forType: .string)
            }
        }
    }

    /// Every other row is tinted, so an eye crossing to the Builds column stays
    /// on the request it started from. Hover wins over the stripe.
    private var background: Color {
        if isHovering { return Color.primary.opacity(0.07) }
        return isAlternate ? Color.primary.opacity(0.03) : .clear
    }

    // MARK: - Summary

    /// Three lines: what it is called, who has it and when it last moved, and
    /// where it is going. The avatar is pinned to the top rather than centred
    /// on all three, so it sits beside the title it belongs to.
    private var summary: some View {
        HStack(alignment: .top, spacing: 10) {
            AuthorAvatar(name: pr.author, url: pr.avatarURL, size: 30)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 7) {
                    StateBadge(pr: pr)
                    Text(pr.title)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(byline)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                branchLine
            }
        }
    }

    /// Where the work is going, on a line of its own. Sharing one with the
    /// byline meant the two competed for the same points, and a branch cut down
    /// to "fe…" tells nobody anything.
    private var branchLine: some View {
        HStack(spacing: 6) {
            BranchChip(name: pr.sourceBranch)
            Image(systemName: "arrow.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            // The target is short and the same on nearly every row, so it is
            // never cut: a `develop` reading `de…` is pure noise.
            BranchChip(name: pr.targetBranch, isFixed: true)
            Spacer(minLength: 0)
        }
    }

    private var byline: String {
        var text = "\(pr.author) · #\(pr.number)"
        if let updated = pr.updatedAt {
            text += ", updated \(updated.formatted(.relative(presentation: .named)))"
        }
        return text
    }

    // MARK: - Created

    /// How old the request is, and nothing more: how old is too old is a
    /// judgement the list has no business making for its reader.
    private var created: some View {
        Group {
            if let createdAt = pr.createdAt {
                Text(createdAt.formatted(.relative(presentation: .named)))
                    .foregroundStyle(.secondary)
            } else {
                missing
            }
        }
        .font(.caption)
        .lineLimit(1)
    }

    // MARK: - Activity

    private var activity: some View {
        Group {
            if let count = pr.commentCount {
                HStack(spacing: 5) {
                    Image(systemName: "text.bubble")
                    Text("\(count)").monospacedDigit()
                }
                // Nothing said yet is worth seeing at a glance, so it fades
                // rather than reading as loudly as a conversation of twelve.
                .foregroundStyle(count == 0 ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
            } else {
                missing
            }
        }
        .font(.caption)
    }

    // MARK: - Reviewers

    /// Up to three faces, overlapped, with the rest counted. Each face already
    /// carries its own verdict badge, so a row of them says both who was asked
    /// and how far they have got.
    private var reviewers: some View {
        Group {
            if pr.reviewers.isEmpty {
                missing
            } else {
                let shown = Array(pr.reviewers.byStanding.prefix(3))
                HStack(spacing: -7) {
                    ForEach(shown) { reviewer in
                        ReviewerFace(reviewer: reviewer, size: 22)
                            .help("\(reviewer.name) — \(reviewer.state.title)")
                    }
                    if pr.reviewers.count > shown.count {
                        Text("+\(pr.reviewers.count - shown.count)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .padding(.leading, 11)
                    }
                }
                .help(pr.reviewers.approvalSummary)
            }
        }
    }

    // MARK: - Builds

    private var builds: some View {
        Group {
            if let state = pr.buildState, state != .unknown {
                Image(systemName: state.symbol)
                    .foregroundStyle(state.color)
                    .font(.system(size: 15))
                    .symbolEffect(.pulse, isActive: state == .running)
                    .help(state.title)
            } else {
                missing
            }
        }
    }

    /// What a column shows when the host never answered for it — a dash, not a
    /// zero and not an empty cell: nothing was said, which is its own fact.
    private var missing: some View {
        Text("—")
            .font(.caption)
            .foregroundStyle(.quaternary)
    }
}

// MARK: - Row furniture

/// The state at the head of a row: Open, Draft, Merged or Closed.
struct StateBadge: View {
    let pr: PullRequest

    private var color: Color {
        if pr.isDraft { return .secondary }
        switch pr.state {
        case .open: return .accentColor
        case .merged: return .purple
        case .closed: return .red
        }
    }

    var body: some View {
        Text(pr.stateBadge.uppercased())
            .font(.system(size: 9, weight: .bold))
            .kerning(0.4)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(color.opacity(0.18), in: Capsule())
    }
}

/// One branch name, boxed. The box is exactly as wide as the name in it.
///
/// There is deliberately no width here at all. A `maxWidth` is not a ceiling on
/// a `Text` — it is an invitation to take that much, which every chip then did,
/// leaving a short branch sitting at one end of a box built for a long one. Cut
/// loose, the chip takes its own width and only gives way when the row runs out
/// of room, and then at the **tail**, because a branch is told apart by the
/// ticket number at the front of it.
struct BranchChip: View {
    let name: String
    /// A short name that should never be cut — the target branch, which is the
    /// same `develop` or `main` on nearly every row. It is the source branch
    /// that gives way when the two cannot both fit.
    var isFixed = false

    var body: some View {
        Text(name)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .fixedSize(horizontal: isFixed, vertical: false)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
            .help(name)
    }
}
