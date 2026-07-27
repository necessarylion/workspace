import SwiftUI

/// The line that sits at the foot of a conversation while Claude is still
/// going: a sparkle, a word, and how long the turn has taken.
///
/// The word is picked from a list and swapped every few seconds, the way the
/// `claude` CLI does it. It says nothing the status does not — that is the
/// point. A turn can spend a minute inside one tool, and a spinner that never
/// changes reads as a hang; a line that keeps finding new words to describe
/// itself reads as work still happening.
///
/// It reads the session from *its own* body rather than being handed the text.
/// What Claude is doing changes many times a turn, and every read of that from
/// the transcript's body rebuilds every bubble in the conversation.
struct ClaudeWorkingLine: View {
    /// The conversation being waited on. Nil when there is nothing to time yet.
    var session: ClaudeSession?

    /// Wording that replaces the rotating one. Starting the CLI is not Claude
    /// working — it is Claude not being there yet — and deserves the plain
    /// sentence rather than a word about thinking.
    var fixed: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Ticks the sparkle and, more slowly, the word. Counted rather than timed
    /// so both come off the same beat.
    @State private var frame = 0
    /// Where in the list this turn starts, so two turns in a row do not open on
    /// the same word. Picked when the line appears.
    @State private var start = 0

    var body: some View {
        HStack(spacing: 8) {
            sparkle
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .task {
            start = Int.random(in: 0..<Self.words.count)
            // A loop rather than a `Timer`: it is cancelled with the view, so a
            // line that has gone away stops asking to be redrawn.
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(Self.beat))
                frame &+= 1
            }
        }
    }

    /// The turning asterisk. Held still, but still drawn, when the reader has
    /// asked for less movement.
    private var sparkle: some View {
        Text(reduceMotion ? Self.glyphs[0] : Self.glyphs[frame % Self.glyphs.count])
            .font(.system(size: 13))
            .foregroundStyle(Self.spark)
            // A fixed box: the glyphs are not all one width, and the word after
            // them should not shuffle sideways on every beat.
            .frame(width: 15)
    }

    private var title: String {
        if let fixed { return fixed }
        return Self.words[(start + frame / Self.wordBeats) % Self.words.count] + "…"
    }

    /// How long it has been going, and what it is doing when the CLI says.
    private var detail: String? {
        let parts = [elapsed, session?.activity.flatMap(Self.activityDetail)].compactMap(\.self)
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Withheld for the first couple of seconds: a clock that opens on "0s" is
    /// noise, and most turns are answered before it would ever have shown.
    private var elapsed: String? {
        guard let since = session?.respondingSince else { return nil }
        let seconds = Int(Date().timeIntervalSince(since))
        guard seconds >= 2 else { return nil }
        guard seconds >= 60 else { return "\(seconds)s" }
        return "\(seconds / 60)m \(String(format: "%02d", seconds % 60))s"
    }

    /// The CLI's one-word status, in words worth reading. Thinking is left out
    /// on purpose — the rotating word already says that, and saying it twice on
    /// one line says it less.
    private static func activityDetail(_ status: String) -> String? {
        switch status {
        case "requesting", "thinking": nil
        case "tool_use", "tool_running": "running a tool"
        default: status.replacingOccurrences(of: "_", with: " ")
        }
    }

    /// Claude's coral, the one colour in the chat that is the brand's rather
    /// than the system's.
    private static let spark = Color(red: 0.851, green: 0.467, blue: 0.341)

    /// One turn of the sparkle, in milliseconds.
    private static let beat = 130
    /// Sparkle beats to a word, so a word lasts about three and a half seconds
    /// — long enough to read twice, short enough that it is clearly ticking.
    private static let wordBeats = 27

    private static let glyphs = ["✳", "✽", "✻", "✼", "✶", "✻", "✽"]

    /// Deliberately useless, deliberately long: the list is only worth having
    /// if you can watch a slow turn without seeing the same word twice.
    private static let words = [
        "Accomplishing", "Actioning", "Baking", "Brewing", "Calculating",
        "Cerebrating", "Channelling", "Churning", "Clauding", "Coalescing",
        "Cogitating", "Computing", "Concocting", "Conjuring", "Considering",
        "Cooking", "Crafting", "Crunching", "Deciphering", "Deliberating",
        "Determining", "Discombobulating", "Doing", "Elucidating", "Enchanting",
        "Envisioning", "Finagling", "Forging", "Frolicking", "Generating",
        "Germinating", "Hatching", "Herding", "Honking", "Hustling", "Ideating",
        "Imagining", "Incubating", "Inferring", "Lubricating", "Manifesting",
        "Marinating", "Meandering", "Moseying", "Mulling", "Mustering", "Musing",
        "Noodling", "Percolating", "Pondering", "Processing", "Puttering",
        "Reticulating", "Ruminating", "Schlepping", "Shimmying", "Simmering",
        "Smoothing", "Smooshing", "Spelunking", "Spinning", "Stewing",
        "Summoning", "Synthesizing", "Thinking", "Tinkering", "Transmuting",
        "Unfurling", "Unravelling", "Vibing", "Wandering", "Whirring",
        "Wibbling", "Working", "Wrangling",
    ]
}
