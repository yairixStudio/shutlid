import AppKit
import ServiceManagement
import ShutlidCore

/// "Shutlid Settings": the four settings and nothing else. Every change is saved at once.
final class SettingsWindow: NSWindow {
    private let keepAwake: KeepAwake
    private let grid = NSGridView(numberOfColumns: 2, rows: 0)
    private let modePopup = NSPopUpButton()
    private let autoOffPopup = NSPopUpButton()
    private let restartPopup = NSPopUpButton()
    private let loginCheckbox = NSButton(checkboxWithTitle: "Launch at login", target: nil, action: nil)
    private let loginHint = SettingsWindow.hint("")
    private let loginOpenButton = NSButton(title: "Open…", target: nil, action: nil)

    /// Popup order for Auto-off; 0 hours means never.
    private static let autoOffChoices = [("1 hour", 1), ("4 hours", 4), ("8 hours", 8), ("24 hours", 24), ("Never", 0)]

    init(keepAwake: KeepAwake) {
        self.keepAwake = keepAwake
        super.init(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Shutlid Settings"
        isReleasedWhenClosed = false
        modePopup.addItems(withTitles: ["Always", "Only while connected to power"])
        autoOffPopup.addItems(withTitles: Self.autoOffChoices.map { $0.0 })
        restartPopup.addItems(withTitles: ["Return to normal sleep", "Restore previous state"])
        for popup in [modePopup, autoOffPopup, restartPopup] {
            popup.target = self
            popup.action = #selector(saveSettings)
        }
        loginCheckbox.target = self
        loginCheckbox.action = #selector(loginChanged)
        loginOpenButton.target = self
        loginOpenButton.action = #selector(openLoginItems)
        loginOpenButton.controlSize = .small
        loginOpenButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)

        grid.addRow(with: [Self.label("Mode:"), modePopup])
        grid.addRow(with: [Self.label("Auto-off after:"), autoOffPopup])
        grid.addRow(with: [Self.label("After restart:"), restartPopup])
        let restartHint = Self.hint(
            "Restored when Shutlid next launches; turn on Launch at login to make it automatic.")
        let loginRow = NSStackView(views: [loginHint, loginOpenButton])
        grid.addRow(with: [NSGridCell.emptyContentView, restartHint])
        grid.addRow(with: [NSGridCell.emptyContentView, loginCheckbox])
        grid.addRow(with: [NSGridCell.emptyContentView, loginRow])  // the last row; hidden unless there is a hint
        grid.rowAlignment = .firstBaseline
        grid.rowSpacing = 10
        grid.column(at: 0).xPlacement = .trailing
        let content = NSStackView(views: [grid])
        content.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        contentView = content
    }

    // NSWindow's NSCoding requirement; this window is never unarchived.
    required init?(coder: NSCoder) { nil }

    func show() {
        loadSettings()
        showLoginItemStatus()
        if !isVisible { center() }
        NSApp.activate()
        makeKeyAndOrderFront(nil)
    }

    // An accessory app has no main menu, so Esc and Cmd-W are handled here.
    override func keyDown(with event: NSEvent) {
        let isEscape = event.keyCode == 53
        let isCommandW = event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "w"
        if isEscape || isCommandW { close() } else { super.keyDown(with: event) }
    }

    // MARK: - Mode, Auto-off, After restart

    private func loadSettings() {
        let settings = keepAwake.settings
        modePopup.selectItem(at: settings.mode == .always ? 0 : 1)
        autoOffPopup.selectItem(at: Self.autoOffChoices.firstIndex { $0.1 == settings.autoOffHours } ?? -1)
        restartPopup.selectItem(at: settings.restoreAfterRestart ? 1 : 0)
    }

    @objc private func saveSettings() {
        var settings = keepAwake.settings
        settings.mode = modePopup.indexOfSelectedItem == 0 ? .always : .onlyOnPower
        if autoOffPopup.indexOfSelectedItem >= 0 {  // -1 only when the stored hours are not a popup choice
            settings.autoOffHours = Self.autoOffChoices[autoOffPopup.indexOfSelectedItem].1
        }
        settings.restoreAfterRestart = restartPopup.indexOfSelectedItem == 1
        if settings != keepAwake.settings { keepAwake.settings = settings }
    }

    // MARK: - Launch at login (owned by macOS through SMAppService; nothing persisted here)

    private func showLoginItemStatus() {
        let status = SMAppService.mainApp.status
        loginCheckbox.state = status == .enabled ? .on : .off
        loginCheckbox.isEnabled = status != .notFound
        switch status {
        case .requiresApproval: setLoginHint("Approve in System Settings › Login Items", showOpen: true)
        case .notFound: setLoginHint("Run from Shutlid.app", showOpen: false)
        default: setLoginHint(nil, showOpen: false)
        }
    }

    @objc private func loginChanged() {
        var failure: String?
        do {
            if loginCheckbox.state == .on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            failure = error.localizedDescription
        }
        showLoginItemStatus()  // the checkbox shows what macOS did, not what was clicked
        if let failure { setLoginHint(failure, showOpen: false) }
    }

    @objc private func openLoginItems() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private func setLoginHint(_ text: String?, showOpen: Bool) {
        loginHint.stringValue = text ?? ""
        loginOpenButton.isHidden = !showOpen
        grid.row(at: grid.numberOfRows - 1).isHidden = text == nil
        setContentSize(contentView!.fittingSize)
    }

    // MARK: - Views

    private static func label(_ text: String) -> NSTextField {
        NSTextField(labelWithString: text)
    }

    private static func hint(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        label.textColor = .secondaryLabelColor
        return label
    }
}
