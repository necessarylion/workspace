import AppKit
import UserNotifications

/// Notification Centre banners for the shells running in the window.
///
/// This exists for Claude Code. A conversation left working in a tab you are
/// not looking at has no way of telling you it is done, and the window spends
/// most of that time behind an editor or a browser — so the one thing the app
/// can usefully add to an embedded terminal is a tap on the shoulder when the
/// program in it wants you back.
///
/// Three things count as wanting you back, and all of them arrive through
/// ``TerminalSession``: the bell (`claude` rings it when it needs an answer),
/// a desktop notification the program asked for itself (OSC 9 / OSC 777, which
/// ghostty hands us as an action), and a turn ending — see
/// ``TerminalSession/readsAsBusy(_:)``.
///
/// There is no switch for this in Settings on purpose: macOS already has one,
/// per app, in System Settings ▸ Notifications, and a second switch that can
/// disagree with it is a support question waiting to happen.
@MainActor
final class TerminalNotifier {
    static let shared = TerminalNotifier()

    /// Called with the shell a banner was about when the user clicks it. The
    /// store sets this; until it does, a click only brings the app forward.
    var onOpen: ((UUID) -> Void)?

    /// The `userInfo` key the shell's id travels under. Read by the delegate,
    /// which carries no actor, hence `nonisolated`.
    nonisolated static let sessionKey = "terminal"

    /// Nil until the user has been asked, then what they answered.
    private var isAllowed: Bool?
    private var isAsking = false
    /// Held here because `UNUserNotificationCenter.delegate` is weak.
    private let delegate = TerminalNotificationDelegate()

    private init() {}

    /// Whether banners are possible at all.
    ///
    /// `UNUserNotificationCenter.current()` does not return nil for an
    /// executable that is not in a bundle — it raises — and the app is built as
    /// a bare binary that `Scripts/bundle.sh` wraps afterwards, so running the
    /// product directly out of the build directory is a real thing that
    /// happens.
    private static var isPossible: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks for permission, once, the first time a shell starts.
    ///
    /// Tied to opening a terminal rather than to launch: the system dialog then
    /// arrives right after something the user did, and someone who never opens
    /// a terminal is never asked at all.
    func prepare() {
        guard Self.isPossible, isAllowed == nil, !isAsking else { return }
        isAsking = true
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            Task { @MainActor in
                TerminalNotifier.shared.isAllowed = granted
                TerminalNotifier.shared.isAsking = false
            }
        }
    }

    /// Puts one banner up for one shell.
    ///
    /// The request is identified by the shell it is about, so a conversation
    /// that says two things in a row replaces its own banner instead of leaving
    /// a stack of them behind.
    func notify(title: String, subtitle: String?, body: String, sessionID: UUID) {
        guard Self.isPossible, isAllowed != false else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        if let subtitle { content.subtitle = subtitle }
        content.body = body
        content.sound = .default
        content.userInfo = [Self.sessionKey: sessionID.uuidString]
        content.threadIdentifier = sessionID.uuidString

        UNUserNotificationCenter.current().add(
            UNNotificationRequest(
                identifier: sessionID.uuidString,
                content: content,
                trigger: nil
            )
        )
    }

    /// A banner was clicked: hand the shell back to whoever is listening.
    fileprivate func open(sessionID: String?) {
        guard let sessionID, let id = UUID(uuidString: sessionID) else { return }
        onOpen?(id)
    }
}

/// The delegate is an object of its own rather than ``TerminalNotifier``
/// itself: the protocol's methods carry no actor of their own, which a
/// `@MainActor` type cannot satisfy under Swift 6. It holds no state, hence
/// `@unchecked Sendable`.
private final class TerminalNotificationDelegate:
    NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// A banner is only ever posted for a shell that is *not* the thing being
    /// looked at, so showing one over the app itself is the point rather than
    /// an oversight — hence presenting it while the app is frontmost.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let id = response.notification.request.content.userInfo[TerminalNotifier.sessionKey] as? String
        // Answered before the hop, so the system is not left waiting on the
        // main actor for a window to come forward.
        completionHandler()
        Task { @MainActor in
            TerminalNotifier.shared.open(sessionID: id)
        }
    }
}
