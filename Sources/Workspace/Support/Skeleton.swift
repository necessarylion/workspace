import AppKit
import SwiftUI

/// The shape of something that has not arrived yet.
///
/// A spinner says only that the app is busy. A skeleton says what is coming and
/// where it will be, so the page does not jump when it lands — the rows are
/// already the right height and the columns already the right width, and what
/// happens on arrival is text replacing grey rather than a layout being built.
///
/// **It is for a first load only.** Anything being *re*-read already has its
/// last answer on screen, and that answer is better than a grey box: the builds
/// panel keeps its list through a failed tick for exactly this reason. A
/// skeleton where a reload happens is a screen that throws away what it knows
/// every few seconds.
///
/// The pulse is one animation for a whole group rather than one per block —
/// see ``SkeletonGroup``. Twenty blocks each running their own repeating
/// animation is twenty timers, and a placeholder must not cost more than the
/// thing it stands in for.
struct Skeleton: View {
    /// How wide, as a fraction of what is offered. Rows of text are ragged, and
    /// a column of identical bars reads as a table rather than as prose.
    var width: CGFloat?
    var height: CGFloat = 12
    var cornerRadius: CGFloat = 4

    @Environment(\.skeletonPulse) private var pulse

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(.quaternary)
            .opacity(pulse)
            .frame(width: width, height: height)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            // It stands for content, and content is read. Nothing here is worth
            // a stop on the way through with the keyboard.
            .accessibilityHidden(true)
    }
}

/// A circle, for where a face goes.
struct SkeletonCircle: View {
    var size: CGFloat = 20

    @Environment(\.skeletonPulse) private var pulse

    var body: some View {
        Circle()
            .fill(.quaternary)
            .opacity(pulse)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// Holds the breath every skeleton inside it takes.
///
/// One repeating animation, published down the tree, rather than one per block.
/// Under Reduce Motion it does not breathe at all — the blocks are still the
/// shape of what is coming, which is the half of this that carries the meaning.
struct SkeletonGroup<Content: View>: View {
    @ViewBuilder var content: Content

    @State private var isDim = false

    var body: some View {
        content
            .environment(\.skeletonPulse, isDim ? 0.45 : 0.85)
            .onAppear {
                guard !ViewerMotion.isReduced else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                    isDim = true
                }
            }
    }
}

private struct SkeletonPulseKey: EnvironmentKey {
    /// What a block outside any group is drawn at: still there, still grey,
    /// simply not breathing.
    static let defaultValue: Double = 0.7
}

extension EnvironmentValues {
    var skeletonPulse: Double {
        get { self[SkeletonPulseKey.self] }
        set { self[SkeletonPulseKey.self] = newValue }
    }
}

// MARK: - The shapes this app waits for

/// A row of the kind the lists in the side panes are made of: a face, a line of
/// text, and a shorter line under it.
struct SkeletonRow: View {
    var hasAvatar = true
    /// Which of the ragged widths this row takes, so a column of them does not
    /// come out as a rectangle.
    var seed: Int = 0

    private static let widths: [CGFloat] = [0.82, 0.64, 0.91, 0.73, 0.58]

    var body: some View {
        HStack(spacing: 8) {
            if hasAvatar {
                SkeletonCircle(size: 20)
            }
            VStack(alignment: .leading, spacing: 5) {
                GeometryReader { geometry in
                    VStack(alignment: .leading, spacing: 5) {
                        Skeleton(width: geometry.size.width * Self.widths[seed % Self.widths.count])
                        Skeleton(width: geometry.size.width * 0.35, height: 9)
                    }
                }
                .frame(height: 26)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// A column of them, for a list that has not come back yet.
struct SkeletonList: View {
    var rows = 5
    var hasAvatar = true

    var body: some View {
        SkeletonGroup {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(0..<rows, id: \.self) { row in
                    SkeletonRow(hasAvatar: hasAvatar, seed: row)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
