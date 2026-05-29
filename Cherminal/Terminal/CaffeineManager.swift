import Combine
import Foundation

/// The coffee button — a one-click "keep this Mac awake" toggle. Mirrors the
/// user's `goodnight` alias forever-mode: `caffeinate -di` (prevent display +
/// idle sleep). On → spawn caffeinate; off → kill it. The child is parented to
/// the app, so quitting Cherminal also ends the caffeinate (no lingering
/// keep-awake). Pure external utility — no injection.
@MainActor
final class CaffeineManager: ObservableObject {
    @Published private(set) var active = false

    private var process: Process?

    func toggle() { active ? stop() : start() }

    private func start() {
        guard process == nil else { return }
        let p = Process()
        p.launchPath = "/usr/bin/caffeinate"
        p.arguments = ["-di"]   // -d no display sleep, -i no idle sleep (cf. `goodnight`)
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        // If caffeinate exits on its own (killed externally, etc.) flip back off.
        p.terminationHandler = { [weak self] _ in
            Task { @MainActor in self?.clear() }
        }
        do { try p.run() } catch { return }
        process = p
        active = true
        clog("caffeine", "on (caffeinate -di pid=\(p.processIdentifier))")
    }

    private func stop() {
        process?.terminationHandler = nil   // we're ending it deliberately
        process?.terminate()
        clear()
        clog("caffeine", "off")
    }

    private func clear() {
        process = nil
        active = false
    }
}
