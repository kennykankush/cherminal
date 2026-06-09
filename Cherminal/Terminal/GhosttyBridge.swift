import Foundation
import GhosttyKit

/// Thin Swift facade over libghostty's build-info call — a link-sanity probe.
/// (The real Config/App/Surface wrappers live in Vendor/Ghostty; this predates
/// them and stays only for the version readout.)
enum GhosttyBridge {
    struct BuildInfo: Sendable {
        let version: String
        let mode: String
    }

    static func info() -> BuildInfo {
        let raw = ghostty_info()
        let version: String
        if let ptr = raw.version {
            let data = Data(bytes: ptr, count: Int(raw.version_len))
            version = String(data: data, encoding: .utf8) ?? "unknown"
        } else {
            version = "unknown"
        }
        return BuildInfo(version: version, mode: modeString(raw.build_mode))
    }

    private static func modeString(_ mode: ghostty_build_mode_e) -> String {
        switch mode {
        case GHOSTTY_BUILD_MODE_DEBUG: "debug"
        case GHOSTTY_BUILD_MODE_RELEASE_SAFE: "release-safe"
        case GHOSTTY_BUILD_MODE_RELEASE_FAST: "release-fast"
        case GHOSTTY_BUILD_MODE_RELEASE_SMALL: "release-small"
        default: "unknown"
        }
    }
}
