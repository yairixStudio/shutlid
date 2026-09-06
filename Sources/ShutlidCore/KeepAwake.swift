import Foundation
import notify

public enum Mode: String {
    case always, onlyOnPower
}

/// Who or what flipped the switch; appears verbatim in the log.
public enum Source: String {
    case gui, cli
    case autoOff = "auto-off"
    case powerMode = "power-mode"
    case restartReset = "restart-reset"
    case restore = "restore-after-restart"
    case quit
}

public struct Settings: Equatable {
    public var mode: Mode
    /// 1, 4, 8 or 24; 0 means never.
    public var autoOffHours: Int
    public var restoreAfterRestart: Bool

    public init(mode: Mode, autoOffHours: Int, restoreAfterRestart: Bool) {
        self.mode = mode
        self.autoOffHours = autoOffHours
        self.restoreAfterRestart = restoreAfterRestart
    }
}

/// The single switch shared by the menu-bar app and the CLI. Last touch wins; there is no owner.
/// Persists the request (`enabled`, `deadline`) and the settings; the kernel is the source of truth
/// for the effective state and is read fresh every time.
public final class KeepAwake {
    private let power: PowerControlling
    private let defaults: UserDefaults
    private let isOnAC: () -> Bool
    private let isSetupInstalled: () -> Bool
    private let now: () -> Date

    private enum Key {
        static let enabled = "enabled"
        static let deadline = "deadline"
        static let mode = "mode"
        static let autoOffHours = "autoOffHours"
        static let restoreAfterRestart = "restoreAfterRestart"
    }

    public init(power: PowerControlling = PowerController(),
                defaults: UserDefaults,
                isOnAC: @escaping () -> Bool = PowerSource.isOnAC,
                isSetupInstalled: @escaping () -> Bool = Setup.isInstalled,
                now: @escaping () -> Date = Date.init) {
        self.power = power
        self.defaults = defaults
        self.isOnAC = isOnAC
        self.isSetupInstalled = isSetupInstalled
        self.now = now
    }

    /// Whether the kernel flag should be set for a given request, mode and power source.
    public static func flagShouldBeOn(requested: Bool, mode: Mode, onAC: Bool) -> Bool {
        requested && (mode == .always || onAC)
    }

    // MARK: - Persisted state

    private var requested: Bool {
        defaults.bool(forKey: Key.enabled)
    }

    private var deadline: Date? {
        defaults.object(forKey: Key.deadline) as? Date
    }

    private func persist(requested: Bool, deadline: Date?) {
        defaults.set(requested, forKey: Key.enabled)
        if let deadline {
            defaults.set(deadline, forKey: Key.deadline)
        } else {
            defaults.removeObject(forKey: Key.deadline)
        }
    }

    private func deadlineFromNow(hours: Int) -> Date? {
        hours == 0 ? nil : now().addingTimeInterval(TimeInterval(hours) * 3600)
    }

    public var settings: Settings {
        get {
            let mode = Mode(rawValue: defaults.string(forKey: Key.mode) ?? "") ?? .always
            let hours = defaults.object(forKey: Key.autoOffHours) == nil ? 24 : defaults.integer(forKey: Key.autoOffHours)
            return Settings(mode: mode, autoOffHours: hours, restoreAfterRestart: defaults.bool(forKey: Key.restoreAfterRestart))
        }
        set {
            let previousHours = settings.autoOffHours
            defaults.set(newValue.mode.rawValue, forKey: Key.mode)
            defaults.set(newValue.autoOffHours, forKey: Key.autoOffHours)
            defaults.set(newValue.restoreAfterRestart, forKey: Key.restoreAfterRestart)
            Log.settingsChanged(newValue)
            // Changing Auto-off while ON restarts the countdown.
            if requested && newValue.autoOffHours != previousHours {
                persist(requested: true, deadline: deadlineFromNow(hours: newValue.autoOffHours))
            }
            try? applyMode()  // failures are already logged inside; the status will show reality
            notifyChanged()
        }
    }

    // MARK: - The switch

    public func status() -> Status {
        let settings = settings
        return Status(requested: requested, effective: power.isPreventingSleep(), mode: settings.mode,
                      onAC: isOnAC(), deadline: deadline, autoOffHours: settings.autoOffHours)
    }

    /// `hours` overrides the configured auto-off (CLI `--for`). Nothing is persisted until the flag step
    /// succeeded, so a failure leaves an existing ON (and its deadline) or an OFF exactly as it was.
    public func turnOn(source: Source, hours: Int? = nil) throws {
        let hours = hours ?? settings.autoOffHours
        let applyFlag = Self.flagShouldBeOn(requested: true, mode: settings.mode, onAC: isOnAC())
        if applyFlag {
            try setFlag(true)
        } else if !isSetupInstalled() {
            // Deferred on battery, but the request must still be honoured later without a password.
            let error = PowerError(kind: .setupRequired, detail: "setup has not been run")
            Log.failure(error.description)
            throw error
        }
        persist(requested: true, deadline: deadlineFromNow(hours: hours))
        Log.turnedOn(source: source, autoOff: Log.autoOffText(hours: hours), deferred: !applyFlag)
        notifyChanged()
    }

    /// Always runs the disable command: `off` must be a sufficient reset even if the registry read is wrong.
    public func turnOff(source: Source) throws {
        do {
            try power.preventSleep(false)
        } catch let error as PowerError where error.kind == .setupRequired && !power.isPreventingSleep() {
            // Fresh machine, nothing to release: `shutlid off` succeeds.
        } catch {
            // Keep the deadline so the app's timer retries the turn-off.
            persist(requested: false, deadline: deadline)
            Log.failure(String(describing: error))
            notifyChanged()
            throw error
        }
        persist(requested: false, deadline: nil)
        Log.turnedOff(source: source)
        notifyChanged()
    }

    /// Reconciles the flag with the mode after a power-source change or a settings write. Deadline unchanged.
    public func applyMode() throws {
        guard requested else { return }
        let want = Self.flagShouldBeOn(requested: true, mode: settings.mode, onAC: isOnAC())
        guard want != power.isPreventingSleep() else { return }
        try setFlag(want)
        if want {
            Log.turnedOn(source: .powerMode, autoOff: deadlineText(), deferred: false)
        } else {
            Log.turnedOff(source: .powerMode)
        }
        notifyChanged()
    }

    /// The only reconciliation, run once when the app starts. Three rules, in order.
    public func applyAtLaunch() throws {
        guard requested else { return }
        if let deadline, deadline <= now() {
            try turnOff(source: .autoOff)
            return
        }
        guard !power.isPreventingSleep() else { return }  // crash case: the request is still in effect
        // The flag is gone (boot reset). No mode gate: a stale request must not survive a reboot.
        if settings.restoreAfterRestart {
            try turnOn(source: .restore)
        } else {
            persist(requested: false, deadline: nil)
            Log.turnedOff(source: .restartReset)
            notifyChanged()
        }
    }

    /// Quit menu: a normal turn-off. Logout/shutdown/restart: release the flag but keep the request
    /// when "restore previous state" is on, which is what makes the restore possible at next login.
    public func releaseForTermination(userInitiated: Bool) throws {
        if userInitiated {
            try turnOff(source: .quit)
            return
        }
        if power.isPreventingSleep() {
            try setFlag(false)
        }
        Log.turnedOff(source: .quit)
        if !settings.restoreAfterRestart {
            persist(requested: false, deadline: nil)
        }
        notifyChanged()
    }

    // MARK: - Helpers

    private func setFlag(_ prevent: Bool) throws {
        do {
            try power.preventSleep(prevent)
        } catch {
            Log.failure(String(describing: error))
            throw error
        }
    }

    private func deadlineText() -> String {
        guard let deadline else { return "never" }
        let now = now()
        return deadline > now ? "in \(Status.remainingText(until: deadline, now: now))" : "expired"
    }

    /// Every state change ends here so the app refreshes its icon at once (it also receives its own posts).
    private func notifyChanged() {
        notify_post(Shutlid.changedNotification)
    }
}
