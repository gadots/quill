import AppKit
import Foundation

/// A failed startup check, rendered for the menu bar along with the Settings
/// pane that fixes it.
///
/// quill runs as an accessory with no window, so a problem that isn't in the
/// menu is a problem the user never learns about — it used to go to stderr,
/// which for a LaunchAgent means a log file nobody opens.
struct Problem {
    let summary: String
    /// Deep link to the relevant Privacy & Security pane, if there is one.
    let settingsURL: URL?

    init?(_ check: Check) {
        guard case .fail(let message) = check.status else { return nil }
        summary = "\(check.name): \(message)"
        settingsURL = Self.settingsPane(for: check.name)
    }

    private static func settingsPane(for checkName: String) -> URL? {
        let anchor: String
        switch checkName {
        case "microphone": anchor = "Privacy_Microphone"
        case "system audio": anchor = "Privacy_ScreenCapture"
        default: return nil
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")
    }

    @MainActor
    func openSettings() {
        guard let settingsURL else { return }
        NSWorkspace.shared.open(settingsURL)
    }
}
