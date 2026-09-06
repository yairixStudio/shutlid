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

/// The three UserDefaults calls KeepAwake needs, so tests can run against an in-memory store.
public protocol Store {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
}

extension UserDefaults: Store {}

/// The single switch shared by the menu-bar app and the CLI. Last touch wins; there is no owner.
/// Persists the request (`enabled`, `deadline`) and the settings; the kernel is the source of truth
/// for the effective state and is read fresh every time.
public final class KeepAwake {
    private let power: PowerControlling
    private let defaults: Store
    private let isOnAC: () -> Bool
    private let isSetupInstalled: () -> Bool
    private let bootSession: () -> String
    private let now: () -> Date

    private enum Key {
        static let enabled = "enabled"
        static let deadline = "deadline"
        static let bootSession = "bootSession"
        static let mode = "mode"
        static let autoOffHours = "autoOffHours"
        static let restoreAfterRestart = "restoreAfterRestart"
    }

    public init(power: PowerControlling = PowerController(),
                defaults: Store = UserDefaults(suiteName: Shutlid.defaultsSuite)!,
                isOnAC: @escaping () -> Bool = PowerSource.isOnAC,
                isSetupInstalled: @escaping () -> Bool = Setup.isInstalled,
                bootSession: @escaping () -> String = BootSession.current,
                now: @escaping () -> Date = Date.init) {
        self.power = power
        self.defaults = defaults
        self.isOnAC = isOnAC
        self.isSetupInstalled = isSetupInstalled
        self.bootSession = bootSession
        self.now = now
    }

    /// Whether the kernel flag should be set for a given request, mode and power source.
    public static func flagShouldBeOn(requested: Bool, mode: Mode, onAC: Bool) -> Bool {
        requested && (mode == .always || onAC)
    }

    // MARK: - Persisted state

    private var requested: Bool {
        defaults.object(forKey: Key.enabled) as? Bool ?? false
    }

    private var deadline: Date? {
        defaults.object(forKey: Key.deadline) as? Date
    }

    /// True when the request was made during the current boot, i.e. the Mac has not restarted since.
    private var requestedThisBoot: Bool {
        let stored = defaults.object(forKey: Key.bootSession) as? String ?? ""
        return !stored.isEmpty && stored == bootSession()
    }

    private func persist(requested: Bool, deadline: Date?) {
        defaults.set(requested, forKey: Key.enabled)
        if let deadline {
            defaults.set(deadline, forKey: Key.deadline)
        } else {
            defaults.removeObject(forKey: Key.deadline)
        }
        if requested {
            defaults.set(bootSession(), forKey: Key.bootSession)
        } else {
            defaults.removeObject(forKey: Key.bootSession)
        }
    }

    private func deadlineFromNow(hours: Int) -> Date? {
        hours == 0 ? nil : now().addingTimeInterval(TimeInterval(hours) * 3600)
    }

    public var settings: Settings {
        get {
            let mode = Mode(rawValue: defaults.object(forKey: Key.mode) as? String ?? "") ?? .always
            let hours = defaults.object(forKey: Key.autoOffHours) as? Int ?? 24
            let restore = defaults.object(forKey: Key.restoreAfterRestart) as? Bool ?? false
            return Settings(mode: mode, autoOffHours: hours, restoreAfterRestart: restore)
        }
        set {
            let previous = settings
            defaults.set(newValue.mode.rawValue, forKey: Key.mode)
            defaults.set(newValue.autoOffHours, forKey: Key.autoOffHours)
            defaults.set(newValue.restoreAfterRestart, forKey: Key.restoreAfterRestart)
            Log.settingsChanged(newValue)
            // Changing Auto-off while ON restarts the countdown.
            if requested && newValue.autoOffHours != previous.autoOffHours {
                persist(requested: true, deadline: deadlineFromNow(hours: newValue.autoOffHours))
            }
            // Changing the mode while ON applies it at once (failures are logged; the status shows reality).
            if requested && newValue.mode != previous.mode {
                try? applyMode()
            }
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
        Log.turnedOn(source: source, autoOff: Status.autoOffText(hours: hours), deferred: !applyFlag)
        notifyChanged()
    }

    /// Always runs the disable command: `off` must be a sufficient reset even if the registry read is wrong.
    public func turnOff(source: Source) throws {
        do {
            try power.preventSleep(false)
        } catch let error as PowerError where error.kind == .setupRequired && !power.isPreventingSleep() {
            // Fresh machine, nothing to release: `shutlid off` succeeds.
        } catch {
            // Fail closed in what is persisted; the kernel flag stays until the manual reset, and the
            // status says so ("turn-off failed").
            persist(requested: false, deadline: nil)
            Log.failure(String(describing: error))
            notifyChanged()
            throw error
        }
        persist(requested: false, deadline: nil)
        Log.turnedOff(source: source)
        notifyChanged()
    }

    /// A power-source event only matters when the mode depends on power. In Always mode a flag that is off
    /// while requested was cleared by hand (`sudo pmset disablesleep 0`) or by the boot reset, and that stands.
    public func powerSourceChanged() throws {
        guard settings.mode == .onlyOnPower else { return }
        try applyMode()
    }

    /// Makes the flag match the mode and the power source while requested. Deadline unchanged.
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
        if power.isPreventingSleep() {
            // Crash case: the request is still in effect. The power source may have changed meanwhile.
            try applyMode()
            return
        }
        if requestedThisBoot && !Self.flagShouldBeOn(requested: true, mode: settings.mode, onAC: isOnAC()) {
            return  // same boot and the flag is meant to be off: a request waiting for power, not a stale one
        }
        // The flag is gone (boot reset or manual reset). No mode gate: a stale request must not survive a reboot.
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

/// Identifies the current boot, so a request can tell a restart from a relaunch of the app.
public enum BootSession {
    public static func current() -> String {
        var size = 0
        guard sysctlbyname("kern.bootsessionuuid", nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.bootsessionuuid", &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }
}
