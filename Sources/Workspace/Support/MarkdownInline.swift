import Foundation

/// The one inline pass.
///
/// cmark answers the whole of the block grammar and most of the inline one, but
/// four things in a comment are not Markdown at all and never were: a bare URL
/// (there is no autolink extension attached), `:tada:`, `#123` and `@name`. They
/// are a scan over the *text* of the document — the `Text` nodes and nothing
/// else — which makes them one piece of work rather than four, and keeps them
/// out of a link's address, a code span and a fence.
///
/// It also does the escaping, and that is the reason this is a single pass. The
/// blocks carry Markdown strings, which the views read back with
/// `AttributedString(markdown:)`; so a `*` the author escaped in the source has
/// to be written back escaped, or it comes out as emphasis the second time
/// round. Every stretch of plain text goes out through ``escaping(_:)`` and
/// everything this pass adds is written as real syntax on purpose.
enum MarkdownInline {
    /// One `Text` node, ready to be put back into a Markdown string.
    ///
    /// `inLink` is set for the words *inside* a link, where nothing is turned
    /// into a link a second time — the address is already the answer.
    static func decorated(_ text: String, links: MarkdownLinks, inLink: Bool) -> String {
        guard text.contains(where: isInteresting) else { return text }
        var result = ""
        // The answer is the text plus a backslash here and there; asking for the
        // room once beats growing it a character at a time.
        result.reserveCapacity(text.count + 16)
        var index = text.startIndex

        while index < text.endIndex {
            let character = text[index]

            // A bare address. First, because one can hold a `#` and an `@`.
            if !inLink, character == "h" || character == "w", isBoundary(before: index, in: text),
               let end = addressEnd(in: text, from: index) {
                let address = String(text[index..<end])
                result += address.hasPrefix("w")
                    ? "[\(escaping(address))](https://\(address))"
                    : "<\(address)>"
                index = end
                continue
            }

            // `[^1]`, which is where a footnote is referred to. cmark has no
            // footnotes, so this would otherwise be read as a link — see
            // `MarkdownParser` for the other half of that hazard.
            if character == "[", let footnote = footnote(in: text, from: index) {
                result += escaping("[\(footnote.label)]")
                index = footnote.end
                continue
            }

            if !inLink, character == "#", isBoundary(before: index, in: text),
               let reference = number(in: text, from: index), let url = links.pullRequest(reference.value) {
                result += "[#\(reference.value)](\(url.absoluteString))"
                index = reference.end
                continue
            }

            if !inLink, character == "@", isBoundary(before: index, in: text),
               let mention = mention(in: text, from: index), let url = links.user(mention.name) {
                result += "[@\(escaping(mention.name))](\(url.absoluteString))"
                index = mention.end
                continue
            }

            if character == ":", let shortcode = shortcode(in: text, from: index) {
                result += shortcode.emoji
                index = shortcode.end
                continue
            }

            if isSignificant(character) { result.append("\\") }
            result.append(character)
            index = text.index(after: index)
        }
        return result
    }

    // MARK: - Escaping

    /// The characters that would be read as syntax the next time round. `>` and
    /// `#` are not among them: the views parse inline Markdown only, so nothing
    /// that only means something at the start of a block can fire.
    ///
    /// A `switch` rather than a `Set<Character>`: this is asked of every
    /// character of every `Text` node in the document, and hashing a grapheme
    /// cluster to answer it is more work than the comparison itself.
    private static func isSignificant(_ character: Character) -> Bool {
        switch character {
        case "\\", "`", "*", "_", "[", "]", "<", "&", "~": true
        default: false
        }
    }

    /// The above, plus the characters that can *start* something this pass adds.
    /// Text with none of them at all — which is most of it — is handed back
    /// untouched without a second look.
    private static func isInteresting(_ character: Character) -> Bool {
        switch character {
        case "h", "t", "w", "#", "@", ":": true
        default: isSignificant(character)
        }
    }

    static func escaping(_ text: String) -> String {
        guard text.contains(where: isSignificant) else { return text }
        var result = ""
        result.reserveCapacity(text.count + 16)
        for character in text {
            if isSignificant(character) { result.append("\\") }
            result.append(character)
        }
        return result
    }

    /// A code span long enough to hold `code` — the fence has to be longer than
    /// the longest run of backticks inside it, and a span that starts or ends
    /// with one needs a space that Markdown then eats again.
    static func codeSpan(_ code: String) -> String {
        var longest = 0
        var run = 0
        for character in code {
            run = character == "`" ? run + 1 : 0
            longest = max(longest, run)
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = code.hasPrefix("`") || code.hasSuffix("`") ? " " : ""
        return fence + pad + code + pad + fence
    }

    /// A link's address as it can be written between the parentheses. Anything
    /// with a space or a bracket in it goes in angle brackets instead, which is
    /// the spelling that has no such trouble.
    static func destination(_ address: String) -> String {
        address.contains(where: { $0 == " " || $0 == "(" || $0 == ")" })
            ? "<\(address)>"
            : address
    }

    // MARK: - What the scan looks for

    /// Nothing that reads as a word may come first, so `abc#12`, an e-mail
    /// address and a path are all left alone.
    private static func isBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !previous.isLetter && !previous.isNumber
            && previous != "_" && previous != "/" && previous != "#" && previous != "@"
    }

    /// The end of a bare `https://…` or `www.…`, with the punctuation a
    /// sentence puts after one left out of it: a full stop is not part of an
    /// address, and neither is the bracket that closes the one it sits in.
    private static func addressEnd(in text: String, from start: String.Index) -> String.Index? {
        let rest = text[start...]
        guard rest.hasPrefix("https://") || rest.hasPrefix("http://") || rest.hasPrefix("www.") else {
            return nil
        }
        var end = rest.firstIndex(where: { $0.isWhitespace || $0 == "<" || $0 == ">" }) ?? text.endIndex
        while end > start {
            let last = text[text.index(before: end)]
            if ".,;:!?\"'".contains(last) {
                end = text.index(before: end)
                continue
            }
            // A trailing bracket belongs to the address only when the address
            // opened one — `(see https://example.com/a)` against a wiki link
            // like `https://example.com/A_(b)`.
            if last == ")" || last == "]" {
                let opening: Character = last == ")" ? "(" : "["
                let inside = text[start..<end]
                if inside.filter({ $0 == opening }).count < inside.filter({ $0 == last }).count {
                    end = text.index(before: end)
                    continue
                }
            }
            break
        }
        // Nothing past the scheme is not an address.
        let minimum = rest.hasPrefix("www.") ? 5 : 9
        return text.distance(from: start, to: end) >= minimum ? end : nil
    }

    private static func footnote(in text: String, from start: String.Index) -> (label: String, end: String.Index)? {
        let rest = text[start...]
        guard rest.hasPrefix("[^"), let close = rest.firstIndex(of: "]") else { return nil }
        let label = rest[rest.index(rest.startIndex, offsetBy: 2)..<close]
        guard !label.isEmpty, label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
            return nil
        }
        return (String(label), rest.index(after: close))
    }

    /// `#123`, capped at six digits so a hex colour is not a pull request —
    /// the same reading `PullRequestReference` gives a commit subject.
    private static func number(in text: String, from start: String.Index) -> (value: Int, end: String.Index)? {
        let digits = text[text.index(after: start)...].prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 6, let value = Int(digits), value > 0 else { return nil }
        let end = text.index(start, offsetBy: digits.count + 1)
        guard end == text.endIndex || !(text[end].isLetter || text[end].isNumber || text[end] == "_") else {
            return nil
        }
        return (value, end)
    }

    private static func mention(in text: String, from start: String.Index) -> (name: String, end: String.Index)? {
        let rest = text[text.index(after: start)...]
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "." }
        guard let first = name.first, first.isLetter || first.isNumber, name.count <= 39 else { return nil }
        // A name does not end in a stop; that one belongs to the sentence.
        let trimmed = name.hasSuffix(".") ? name.dropLast() : name
        guard !trimmed.isEmpty else { return nil }
        return (String(trimmed), text.index(start, offsetBy: trimmed.count + 1))
    }

    private static func shortcode(in text: String, from start: String.Index) -> (emoji: String, end: String.Index)? {
        let rest = text[text.index(after: start)...]
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }
        guard !name.isEmpty, name.count <= 40 else { return nil }
        let close = text.index(start, offsetBy: name.count + 1)
        guard close < text.endIndex, text[close] == ":", let emoji = Self.emoji[String(name)] else { return nil }
        return (emoji, text.index(after: close))
    }

    /// The shortcodes a comment actually reaches for. Not all of GitHub's
    /// eighteen hundred: the ones a person, a release note and a review bot
    /// write, plus the whole of the flag-free everyday set. One a reader does
    /// not find here stays as the `:name:` it was written as, which is what
    /// both hosts do with a shortcode they do not know either.
    private static let emoji: [String: String] = [
        "+1": "👍", "-1": "👎", "100": "💯", "alarm_clock": "⏰", "alien": "👽",
        "ambulance": "🚑", "angry": "😠", "anguished": "😧", "apple": "🍎", "art": "🎨",
        "arrow_down": "⬇️", "arrow_left": "⬅️", "arrow_right": "➡️", "arrow_up": "⬆️",
        "astonished": "😲", "baby": "👶", "balloon": "🎈", "bang": "❗", "bar_chart": "📊",
        "beer": "🍺", "beers": "🍻", "bell": "🔔", "birthday": "🎂", "black_circle": "⚫",
        "blue_book": "📘", "blue_circle": "🔵", "blush": "😊", "bomb": "💣", "book": "📖",
        "bookmark": "🔖", "books": "📚", "boom": "💥", "brain": "🧠", "bug": "🐛",
        "building_construction": "🏗️", "bulb": "💡", "cake": "🍰", "calendar": "📅",
        "camera": "📷", "car": "🚗", "cat": "🐱", "chart_with_upwards_trend": "📈",
        "chart_with_downwards_trend": "📉", "checkered_flag": "🏁", "cheers": "🥂",
        "cherry_blossom": "🌸", "christmas_tree": "🎄", "clap": "👏", "clipboard": "📋",
        "closed_lock_with_key": "🔐", "cloud": "☁️", "clown_face": "🤡", "coffee": "☕",
        "computer": "💻", "confetti_ball": "🎊", "confused": "😕", "construction": "🚧",
        "construction_worker": "👷", "cookie": "🍪", "cool": "🆒", "cop": "👮",
        "crossed_fingers": "🤞", "crown": "👑", "cry": "😢", "crystal_ball": "🔮",
        "dancer": "💃", "dart": "🎯", "dash": "💨", "date": "📅", "detective": "🕵️",
        "disappointed": "😞", "dizzy": "💫", "dog": "🐶", "door": "🚪", "dollar": "💵",
        "double_exclamation_mark": "‼️", "dragon": "🐉", "droplet": "💧", "eyes": "👀",
        "earth_africa": "🌍", "earth_americas": "🌎", "earth_asia": "🌏", "egg": "🥚",
        "email": "📧", "envelope": "✉️", "exclamation": "❗", "eye": "👁️", "face_with_monocle": "🧐",
        "facepalm": "🤦", "fire": "🔥", "fire_engine": "🚒", "first_quarter_moon": "🌓",
        "fish": "🐟", "flashlight": "🔦", "floppy_disk": "💾", "flushed": "😳", "fox_face": "🦊",
        "frowning": "😦", "gear": "⚙️", "gem": "💎", "ghost": "👻", "gift": "🎁",
        "globe_with_meridians": "🌐", "goal_net": "🥅", "grey_exclamation": "❕",
        "grey_question": "❔", "grimacing": "😬", "grin": "😁", "grinning": "😀",
        "green_book": "📗", "green_circle": "🟢", "green_heart": "💚", "gun": "🔫",
        "hammer": "🔨", "hammer_and_wrench": "🛠️", "hand": "✋", "handshake": "🤝",
        "hankey": "💩", "hash": "#️⃣", "headphones": "🎧", "heart": "❤️", "heart_eyes": "😍",
        "heavy_check_mark": "✔️", "heavy_exclamation_mark": "❗", "heavy_minus_sign": "➖",
        "heavy_multiplication_x": "✖️", "heavy_plus_sign": "➕", "hocho": "🔪",
        "hourglass": "⌛", "hourglass_flowing_sand": "⏳", "house": "🏠", "hugs": "🤗",
        "ice_cube": "🧊", "id": "🆔", "inbox_tray": "📥", "information_source": "ℹ️",
        "innocent": "😇", "izakaya_lantern": "🏮", "jack_o_lantern": "🎃", "joy": "😂",
        "key": "🔑", "keyboard": "⌨️", "kiss": "💋", "koala": "🐨", "label": "🏷️",
        "laughing": "😆", "leftwards_arrow_with_hook": "↩️", "lemon": "🍋", "link": "🔗",
        "lion": "🦁", "lipstick": "💄", "lock": "🔒", "loud_sound": "🔊", "loudspeaker": "📢",
        "mag": "🔍", "mag_right": "🔎", "mailbox": "📫", "man": "👨", "man_shrugging": "🤷‍♂️",
        "medal": "🏅", "mega": "📣", "memo": "📝", "microphone": "🎤", "microscope": "🔬",
        "milky_way": "🌌", "money_with_wings": "💸", "moneybag": "💰", "monkey": "🐒",
        "moon": "🌔", "mortar_board": "🎓", "mountain": "⛰️", "mouse": "🐭",
        "muscle": "💪", "musical_note": "🎵", "nail_care": "💅", "nerd_face": "🤓",
        "new": "🆕", "new_moon": "🌑", "newspaper": "📰", "night_with_stars": "🌃",
        "no_entry": "⛔", "no_entry_sign": "🚫", "notebook": "📓", "nut_and_bolt": "🔩",
        "o": "⭕", "ocean": "🌊", "octocat": "🐙", "ok": "🆗", "ok_hand": "👌",
        "open_book": "📖", "open_file_folder": "📂", "orange_book": "📙", "orange_circle": "🟠",
        "outbox_tray": "📤", "package": "📦", "page_facing_up": "📄", "paperclip": "📎",
        "part_alternation_mark": "〽️", "partying_face": "🥳", "pause_button": "⏸️",
        "paw_prints": "🐾", "pencil": "📝", "pencil2": "✏️", "penguin": "🐧",
        "performing_arts": "🎭", "phone": "☎️", "pill": "💊", "pizza": "🍕",
        "point_down": "👇", "point_left": "👈", "point_right": "👉", "point_up": "☝️",
        "police_car": "🚓", "poop": "💩", "pray": "🙏", "purple_circle": "🟣",
        "purple_heart": "💜", "purse": "👛", "pushpin": "📌", "question": "❓",
        "rabbit": "🐰", "racehorse": "🐎", "radioactive": "☢️", "rainbow": "🌈",
        "raised_hands": "🙌", "recycle": "♻️", "red_circle": "🔴", "registered": "®️",
        "repeat": "🔁", "rewind": "⏪", "robot": "🤖", "rocket": "🚀", "rofl": "🤣",
        "roller_coaster": "🎢", "rotating_light": "🚨", "runner": "🏃", "sailboat": "⛵",
        "santa": "🎅", "satellite": "🛰️", "scales": "⚖️", "school": "🏫", "scissors": "✂️",
        "scream": "😱", "scroll": "📜", "seedling": "🌱", "shield": "🛡️", "ship": "🚢",
        "shipit": "🐐", "shrug": "🤷", "signal_strength": "📶", "skull": "💀",
        "skull_and_crossbones": "☠️", "sleeping": "😴", "sleuth_or_spy": "🕵️",
        "small_red_triangle": "🔺", "smile": "😄", "smiley": "😃", "smirk": "😏",
        "snail": "🐌", "snake": "🐍", "snowflake": "❄️", "sob": "😭", "sos": "🆘",
        "sparkler": "🎇", "sparkles": "✨", "speech_balloon": "💬", "speedboat": "🚤",
        "star": "⭐", "star2": "🌟", "stars": "🌠", "stop_sign": "🛑", "stopwatch": "⏱️",
        "sun_with_face": "🌞", "sunny": "☀️", "sunrise": "🌅", "sweat_drops": "💦",
        "sweat_smile": "😅", "syringe": "💉", "tada": "🎉", "telephone": "☎️",
        "telescope": "🔭", "tent": "⛺", "test_tube": "🧪", "thinking": "🤔",
        "thought_balloon": "💭", "thumbsdown": "👎", "thumbsup": "👍", "ticket": "🎫",
        "tiger": "🐯", "tm": "™️", "toolbox": "🧰", "tools": "🛠️", "top": "🔝",
        "trophy": "🏆", "truck": "🚚", "turtle": "🐢", "unicorn": "🦄", "unlock": "🔓",
        "up": "🆙", "v": "✌️", "vertical_traffic_light": "🚦", "warning": "⚠️",
        "wastebasket": "🗑️", "watch": "⌚", "water_buffalo": "🐃", "wave": "👋",
        "wavy_dash": "〰️", "weary": "😩", "white_check_mark": "✅", "white_circle": "⚪",
        "wilted_flower": "🥀", "wind_face": "🌬️", "wink": "😉", "wolf": "🐺",
        "woman": "👩", "woman_shrugging": "🤷‍♀️", "wrench": "🔧", "writing_hand": "✍️",
        "x": "❌", "yellow_circle": "🟡", "yellow_heart": "💛", "yum": "😋",
        "zany_face": "🤪", "zap": "⚡", "zzz": "💤",
    ]
}
