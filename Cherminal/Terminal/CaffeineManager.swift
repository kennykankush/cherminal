import Combine
import Foundation
import IOKit.pwr_mgt

/// The coffee button — a one-click "keep this Mac awake" toggle. Same effect
/// as `caffeinate -di` (prevent display sleep + idle system sleep), but held
/// as IOKit power assertions IN-PROCESS rather than by spawning a child.
///
/// Why not spawn `caffeinate`: a child process is NOT killed when its parent
/// exits — Unix reparents it to launchd, where a `caffeinate -di` keeps
/// asserting "never sleep" forever. Every Cherminal quit/crash with the
/// toggle on leaked one immortal caffeinate (four found alive in the wild,
/// the oldest 4 days, 2026-06-13) and the Mac could never idle-sleep again.
/// IOKit assertions are owned by THIS process; the kernel releases them the
/// instant the process dies — crash, force-quit, or clean quit — so the leak
/// is structurally impossible. Pure external utility — no injection.
@MainActor
final class CaffeineManager: ObservableObject {
    @Published private(set) var active = false

    /// The two assertions that together equal `caffeinate -di`: keep the
    /// display awake (`-d`) and prevent idle system sleep (`-i`). 0 = unheld.
    private var displayAssertion: IOPMAssertionID = 0
    private var systemAssertion: IOPMAssertionID = 0

    func toggle() { active ? stop() : start() }

    private func start() {
        guard !active else { return }
        let reason = "Cherminal keep-awake" as CFString
        let display = createAssertion(kIOPMAssertionTypePreventUserIdleDisplaySleep, reason)
        let system = createAssertion(kIOPMAssertionTypePreventUserIdleSystemSleep, reason)
        // If neither assertion could be created, leave the toggle off rather
        // than claim a keep-awake we aren't actually holding.
        guard display != 0 || system != 0 else { return }
        displayAssertion = display
        systemAssertion = system
        active = true
        clog("caffeine", "on (IOKit display=\(display) system=\(system))")
    }

    private func stop() {
        release(&displayAssertion)
        release(&systemAssertion)
        active = false
        clog("caffeine", "off")
    }

    private func createAssertion(_ type: String, _ reason: CFString) -> IOPMAssertionID {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(
            type as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason,
            &id)
        return result == kIOReturnSuccess ? id : 0
    }

    private func release(_ id: inout IOPMAssertionID) {
        guard id != 0 else { return }
        IOPMAssertionRelease(id)
        id = 0
    }
}
