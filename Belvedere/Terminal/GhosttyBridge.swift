import Foundation
import GhosttyKit

/// Thin Swift facade over the libghostty C API. Phase 1 only exposes build
/// info — enough to prove the xcframework links and the C bridge works.
/// Later phases will add Config, App, and Surface wrappers.
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
