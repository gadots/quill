import AppKit

/// Status bar item in the top-right of the menu bar. Shows recording state at
/// a glance and provides the only persistent control surface for the daemon
/// (since we run as `.accessory` — no dock icon, no main window).
@MainActor
final class MenuBarController {
    private let statusItem: NSStatusItem
    private let stateLabel: NSMenuItem
    private let transcriptionLabel: NSMenuItem
    private let toggleItem: NSMenuItem
    private let menu: NSMenu
    /// Problem rows sit above the state label and are rebuilt wholesale, so
    /// they're tracked separately from the fixed items.
    private var problemItems: [NSMenuItem] = []
    private var problems: [Problem] = []

    var onToggle: (() -> Void)?
    var onOpenFolder: (() -> Void)?
    var onQuit: (() -> Void)?

    init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        menu = NSMenu()
        menu.autoenablesItems = false

        stateLabel = NSMenuItem(title: "idle", action: nil, keyEquivalent: "")
        stateLabel.isEnabled = false
        menu.addItem(stateLabel)

        transcriptionLabel = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        transcriptionLabel.isEnabled = false
        transcriptionLabel.isHidden = true
        menu.addItem(transcriptionLabel)

        menu.addItem(.separator())

        toggleItem = NSMenuItem(
            title: "Start recording",
            action: #selector(toggleClicked),
            keyEquivalent: "r"
        )
        menu.addItem(toggleItem)

        let openFolder = NSMenuItem(
            title: "Open recordings folder",
            action: #selector(openFolderClicked),
            keyEquivalent: "o"
        )
        menu.addItem(openFolder)

        menu.addItem(.separator())

        let quit = NSMenuItem(
            title: "Quit quill",
            action: #selector(quitClicked),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        for item in [toggleItem, openFolder, quit] {
            item.target = self
        }

        statusItem.menu = menu

        if let button = statusItem.button {
            let image = Self.featherImage()
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeft
        }
    }

    /// Reflect recording state in the icon tint and menu item titles. The
    /// menu bar shows only the feather (red while recording); the elapsed
    /// counter lives in the menu's state label. Call once a second while
    /// recording.
    func update(recording: Bool, elapsed: String?) {
        stateLabel.title = recording ? "● recording · \(elapsed ?? "0:00")" : "idle"
        toggleItem.title = recording ? "Stop recording" : "Start recording"
        // Recording beats a standing problem for the icon tint; the problem
        // rows stay in the menu either way.
        statusItem.button?.contentTintColor =
            recording ? .systemRed : (problems.isEmpty ? nil : .systemOrange)
    }

    /// Replace the problem rows at the top of the menu. Each failed check
    /// gets a line, plus a clickable row that opens the Settings pane which
    /// fixes it. Empty list removes the section.
    func showProblems(_ problems: [Problem]) {
        for item in problemItems {
            menu.removeItem(item)
        }
        problemItems = []
        self.problems = problems
        guard !problems.isEmpty else {
            statusItem.button?.contentTintColor = nil
            return
        }

        var index = 0
        for (offset, problem) in problems.enumerated() {
            let label = NSMenuItem(title: "⚠ \(problem.summary)", action: nil, keyEquivalent: "")
            label.isEnabled = false
            menu.insertItem(label, at: index)
            problemItems.append(label)
            index += 1

            if problem.settingsURL != nil {
                let fix = NSMenuItem(
                    title: "Open Settings to fix…",
                    action: #selector(problemClicked(_:)),
                    keyEquivalent: ""
                )
                fix.target = self
                fix.tag = offset
                menu.insertItem(fix, at: index)
                problemItems.append(fix)
                index += 1
            }
        }

        let separator = NSMenuItem.separator()
        menu.insertItem(separator, at: index)
        problemItems.append(separator)

        statusItem.button?.contentTintColor = .systemOrange
        statusItem.button?.toolTip = problems.map(\.summary).joined(separator: "\n")
    }

    /// Show transcription progress/failure as a second status line in the
    /// menu; nil hides it. Independent of recording state — a new recording
    /// can run while the last one transcribes.
    func updateTranscription(_ text: String?) {
        transcriptionLabel.title = text ?? ""
        transcriptionLabel.isHidden = text == nil
    }

    // Inlined Lucide feather SVG. Keeping it in source means the executable
    // has no separate resource bundle to install alongside it — true
    // single-binary.
    private static let featherSVG = """
    <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" \
    viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" \
    stroke-linecap="round" stroke-linejoin="round">\
    <path d="M12.67 19a2 2 0 0 0 1.416-.588l6.154-6.172a6 6 0 0 0-8.49-8.49L5.586 9.914A2 2 0 0 0 5 11.328V18a1 1 0 0 0 1 1z"/>\
    <path d="M16 8 2 22"/>\
    <path d="M17.5 15H9"/>\
    </svg>
    """

    private static func featherImage() -> NSImage? {
        guard let data = featherSVG.data(using: .utf8),
              let image = NSImage(data: data)
        else { return nil }
        // Menu-bar status icons are nominally 18pt tall; size the SVG to match.
        image.size = NSSize(width: 16, height: 16)
        return image
    }

    @objc private func problemClicked(_ sender: NSMenuItem) {
        guard problems.indices.contains(sender.tag) else { return }
        problems[sender.tag].openSettings()
    }

    @objc private func toggleClicked() { onToggle?() }
    @objc private func openFolderClicked() { onOpenFolder?() }
    @objc private func quitClicked() { onQuit?() }
}
