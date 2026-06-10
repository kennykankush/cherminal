import AppKit
import Combine
import Foundation

/// One session registered with claude's background-agent supervisor
/// (`claude agents --json`): headless dispatched sessions AND interactive
/// ones running in other terminals — everything alive that Cherminal isn't
/// already showing in a pane.
struct BackgroundSession: Identifiable, Equatable, Sendable {
    let pid: Int32
    let cwd: String
    let kind: String
    let sessionId: String
    let name: String?
    let status: String        // "busy" | "idle" | "waiting" (open vocabulary)
    let waitingFor: String?

    var id: String { sessionId }
    var roomName: String { URL(fileURLWithPath: cwd).lastPathComponent }
    /// The session is blocked on the human (permission prompt, input).
    var needsYou: Bool { status == "waiting" }
    var isBusy: Bool { status == "busy" }
}

/// Surfaces the supervisor's live session list — pure external observation
/// (one bounded `claude agents --json` subprocess per poll, foreground-only).
/// The sidebar shows the ones not already open as a Cherminal pane, with
/// one-click attach (`claude attach <id>`, which detaches with ^Z and leaves
/// the session running — exactly dtach-like semantics).
@MainActor
final class BackgroundAgentsMonitor: ObservableObject {
    @Published private(set) var sessions: [BackgroundSession] = []

    private var timer: Timer?
    private var polling = false
    private var consecutiveFailures = 0
    private let interval: TimeInterval = 15

    func start() {
        guard timer == nil else { return }
        Task { await poll() }
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard NSApp.isActive else { return }   // ambient info; sleep in background
                await self?.poll()
            }
        }
    }

    private func poll() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        let parsed = await Task.detached(priority: .utility) { () -> [BackgroundSession]? in
            let bin = BinaryResolver.shared.path(for: "claude")
            guard let out = Subprocess.stdout(bin, ["agents", "--json"], timeout: 10) else { return nil }
            return Self.parse(out)
        }.value
        if let parsed {
            consecutiveFailures = 0
            if parsed != sessions { sessions = parsed }
        } else {
            // Keep the last-known list through a transient failure (a wedged
            // supervisor probe shouldn't blank the section), but clear after
            // repeated misses so dead state can't linger forever.
            consecutiveFailures += 1
            if consecutiveFailures >= 3, !sessions.isEmpty { sessions = [] }
        }
    }

    /// Pure parse of `claude agents --json` (testable). Unknown fields are
    /// ignored; unknown status strings pass through (open vocabulary).
    nonisolated static func parse(_ json: String) -> [BackgroundSession]? {
        guard let data = json.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return nil }
        return arr.compactMap { obj in
            guard let sessionId = obj["sessionId"] as? String,
                  let cwd = obj["cwd"] as? String else { return nil }
            return BackgroundSession(
                pid: Int32((obj["pid"] as? Int) ?? 0),
                cwd: cwd,
                kind: (obj["kind"] as? String) ?? "unknown",
                sessionId: sessionId,
                name: obj["name"] as? String,
                status: (obj["status"] as? String) ?? "unknown",
                waitingFor: obj["waitingFor"] as? String)
        }
    }
}
