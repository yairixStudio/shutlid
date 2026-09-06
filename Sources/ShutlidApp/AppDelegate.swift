import AppKit
import notify
import ShutlidCore

/// The status item, its menu, the single auto-off timer, and the app's start and end.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let keepAwake = KeepAwake(defaults: UserDefaults(suiteName: Shutlid.defaultsSuite)!)
    private lazy var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private var settingsWindow: SettingsWindow?
    private var autoOffTimer: DispatchSourceTimer?
    /// A deadline whose auto-off already failed. refresh() does not schedule it again, so a failing
    /// turn-off cannot loop through its own change notification; a new Turn On brings a new deadline.
    private var failedDeadline: Date?
    private var released = false
    private var changedToken: Int32 = 0
    private var powerToken: Int32 = 0

    // MARK: - Launch and termination

    func applicationDidFinishLaunching(_ notification: Notification) {
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        try? keepAwake.applyAtLaunch()  // failures are logged by the core; the icon and menu show reality
        refresh()
        notify_register_dispatch(Shutlid.changedNotification, &changedToken, .main) { [weak self] _ in
            self?.refresh()
        }
        // Second guard: the wall timer should fire on wake anyway; a refresh also catches a deadline passed during sleep.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(refresh), name: NSWorkspace.didWakeNotification, object: nil)
        powerToken = PowerSource.observeChanges { [weak self] in
            guard let self else { return }
            try? self.keepAwake.applyMode()  // failures are logged by the core
            self.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        release(userInitiated: false)
    }

    @objc private func quit() {
        release(userInitiated: true)
        NSApp.terminate(nil)
    }

    /// Runs once: after the Quit menu released, applicationWillTerminate finds nothing left to do.
    private func release(userInitiated: Bool) {
        guard !released else { return }
        released = true
        do {
            try keepAwake.releaseForTermination(userInitiated: userInitiated)
        } catch {
            // Logged by the core. Only a person can be told; a logout or shutdown does not wait for an alert.
            if userInitiated { showTurnOffFailure(error) }
        }
    }

    // MARK: - Status item, timer and menu

    /// The one place that reads the status, sets the icon and (re)schedules the single auto-off timer.
    @objc private func refresh() {
        let status = keepAwake.status()
        statusItem.button?.image = icon(for: status)
        autoOffTimer?.cancel()
        autoOffTimer = nil
        guard let deadline = status.deadline, deadline != failedDeadline else { return }
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // Wall clock, not mach time: mach time stops while the Mac sleeps. A past deadline fires immediately.
        timer.schedule(wallDeadline: .now() + deadline.timeIntervalSinceNow, leeway: .seconds(30))
        timer.setEventHandler { [weak self] in self?.autoOff(at: deadline) }
        timer.resume()
        autoOffTimer = timer
    }

    private func autoOff(at deadline: Date) {
        do {
            try keepAwake.turnOff(source: .autoOff)
        } catch {
            // The core kept the deadline and logged the failure. Remember it before the alert: the change
            // notification arrives during the modal alert and must not reschedule the same deadline.
            failedDeadline = deadline
            showTurnOffFailure(error)
        }
    }

    private func icon(for status: Status) -> NSImage? {
        if status.effective {
            return NSImage(systemSymbolName: "sun.max.fill", accessibilityDescription: "Shutlid: keeping awake")
        }
        if status.isOnLike {
            return NSImage(systemSymbolName: "sun.min", accessibilityDescription: "Shutlid: waiting for power")
        }
        return NSImage(systemSymbolName: "moon.zzz", accessibilityDescription: "Shutlid: normal sleep")
    }

    func menuWillOpen(_ menu: NSMenu) {
        let status = keepAwake.status()
        menu.removeAllItems()
        menu.addItem(withTitle: status.menuTitle(now: Date()), action: nil, keyEquivalent: "").isEnabled = false
        if status.isOnLike {
            addItem("Turn Off", #selector(turnOff))
        } else {
            addItem("Turn On", #selector(turnOn))
        }
        menu.addItem(.separator())
        addItem("Settings…", #selector(openSettings))
        addItem("About", #selector(showAbout))
        addItem("Quit", #selector(quit))
    }

    private func addItem(_ title: String, _ action: Selector) {
        menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
    }

    // MARK: - Menu actions

    @objc private func turnOn() {
        do {
            try keepAwake.turnOn(source: .gui)
        } catch let error as PowerError where error.kind == .setupRequired {
            runSetupThenTurnOn()
        } catch {
            showAlert("Shutlid could not turn keep-awake on.", String(describing: error))
        }
    }

    @objc private func turnOff() {
        do {
            try keepAwake.turnOff(source: .gui)
        } catch {
            showTurnOffFailure(error)
        }
    }

    @objc private func openSettings() {
        if settingsWindow == nil { settingsWindow = SettingsWindow(keepAwake: keepAwake) }
        settingsWindow?.show()
    }

    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(
            options: [.applicationName: Shutlid.appName, .applicationVersion: Shutlid.version])
    }

    // MARK: - One-time setup through the standard administrator dialog

    private func runSetupThenTurnOn() {
        let alert = NSAlert()
        alert.messageText = "Shutlid needs a one-time administrator authorization "
            + "to install a scoped sudo rule and a boot-time reset."
        alert.informativeText = "macOS will ask for your password."
        alert.addButton(withTitle: "Continue")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The CLI ships next to this executable in Contents/MacOS. The script quotes the path itself.
        let cliPath = Bundle.main.executableURL!.deletingLastPathComponent().appendingPathComponent("shutlid").path
        let script = "do shell script (quoted form of item 1 of argv) & \" setup\" with administrator privileges"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", "on run argv", "-e", script, "-e", "end run", cliPath]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        let stderr = Pipe()
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            showSetupFailure(error.localizedDescription, cliPath: cliPath)
            return
        }
        // Off the main thread so the menu bar stays responsive while the password dialog is up.
        DispatchQueue.global().async {
            let errorText = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            DispatchQueue.main.async {
                self.finishSetup(status: process.terminationStatus, stderr: errorText, cliPath: cliPath)
            }
        }
    }

    private func finishSetup(status: Int32, stderr: String, cliPath: String) {
        guard status == 0 else {
            // "(-128)" is osascript's code for the person cancelling the password dialog: stay silent.
            if !stderr.contains("(-128)") {
                showSetupFailure(stderr.trimmingCharacters(in: .whitespacesAndNewlines), cliPath: cliPath)
            }
            return
        }
        do {
            try keepAwake.turnOn(source: .gui)
        } catch {
            showAlert("Setup finished, but Shutlid could not turn keep-awake on.", String(describing: error))
        }
    }

    private func showSetupFailure(_ detail: String, cliPath: String) {
        showAlert("Setup did not complete.", "\(detail)\n\nTo run it by hand, in Terminal:\nsudo \"\(cliPath)\" setup")
    }

    // MARK: - Alerts

    private func showTurnOffFailure(_ error: Error) {
        showAlert("Shutlid could not turn keep-awake off.",
                  "\(error)\n\nTo return to normal sleep, in Terminal:\n\(PowerController.manualResetCommand)")
    }

    private func showAlert(_ message: String, _ detail: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        NSApp.activate()
        alert.runModal()
    }
}
