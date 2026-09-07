import Foundation
import IOKit
import IOKit.ps
import notify

// This is the only file that spells pmset/sudo or talks to IOKit. If Apple changes power
// management, only this file should need to change.

public protocol PowerControlling {
    /// What the kernel is doing right now. Never throws; unknown reads as false.
    func isPreventingSleep() -> Bool
    /// Sets the kernel flag through the privileged command. Throws PowerError.
    func preventSleep(_ prevent: Bool) throws
    /// The battery Energy Mode: 0 automatic, 1 low power, 2 high power. nil when unreadable.
    func batteryPowerMode() -> Int?
    /// Sets the battery Energy Mode through the privileged command. Throws PowerError.
    func setBatteryPowerMode(_ mode: Int) throws
}

public struct PowerError: Error, CustomStringConvertible {
    public enum Kind { case setupRequired, commandFailed }
    public let kind: Kind
    public let detail: String

    public init(kind: Kind, detail: String) {
        self.kind = kind
        self.detail = detail
    }

    public var description: String {
        switch kind {
        case .setupRequired: return "setup required (\(detail))"
        case .commandFailed: return detail
        }
    }
}

public struct PowerController: PowerControlling {
    /// The only place the privileged commands are spelled. Setup builds the sudoers rule and the
    /// boot-reset plist from these.
    public static let enableCommand = ["/usr/bin/pmset", "disablesleep", "1"]
    public static let disableCommand = ["/usr/bin/pmset", "disablesleep", "0"]
    /// `pmset -b powermode N` is the battery Energy Mode from System Settings › Battery:
    /// 0 automatic, 1 low power, 2 high power. Low power caps CPU and GPU power, so less heat.
    public static let lowPowerMode = 1
    public static let batteryPowerModes = [0, 1, 2]
    public static func batteryPowerModeCommand(_ mode: Int) -> [String] {
        ["/usr/bin/pmset", "-b", "powermode", String(mode)]
    }
    /// Every command the sudoers rule permits, in the order setup writes them.
    public static var ruleCommandList: [[String]] {
        [enableCommand, disableCommand] + batteryPowerModes.map(batteryPowerModeCommand)
    }
    /// The command part of the sudoers rule, exactly as `sudo -l` prints it back.
    public static var ruleCommands: String {
        ruleCommandList.map { $0.joined(separator: " ") }.joined(separator: ", ")
    }
    /// What a person types to reset the flag by hand when everything else failed.
    public static let manualResetCommand = "sudo pmset disablesleep 0"
    /// `sudo -l` with these flags lists the caller's rules and never prompts (`-n`); `-k` ignores cached credentials.
    public static let listRulesArguments = ["-k", "-n", "-l"]

    /// sudo prints one of these when no rule permits the command. The text is stable and not localised.
    private static let setupRequiredMarkers = ["a password is required", "not allowed", "may not run"]

    public init() {}

    public func isPreventingSleep() -> Bool {
        (rootDomainProperty("SleepDisabled") as? Bool) ?? false
    }

    public func preventSleep(_ prevent: Bool) throws {
        try runPrivilegedOrThrow(prevent ? Self.enableCommand : Self.disableCommand)
        guard isPreventingSleep() == prevent else {
            // Never leave the flag half-set: if enabling did not take, make sure it is off.
            if prevent { _ = runPrivileged(Self.disableCommand) }
            throw PowerError(kind: .commandFailed, detail: "kernel did not confirm")
        }
    }

    /// Read without root from `pmset -g custom`: the "Battery Power:" section has " powermode N"
    /// (or " lowpowermode N" on Macs without a High Power option).
    public func batteryPowerMode() -> Int? {
        var inBattery = false
        for line in runCommand("/usr/bin/pmset", ["-g", "custom"]).stdout.split(separator: "\n") {
            if line.hasSuffix("Power:") {
                inBattery = line.hasPrefix("Battery")
                continue
            }
            let parts = line.split(separator: " ")
            if inBattery, parts.count == 2, parts[0] == "powermode" || parts[0] == "lowpowermode" {
                return Int(parts[1])
            }
        }
        return nil
    }

    public func setBatteryPowerMode(_ mode: Int) throws {
        try runPrivilegedOrThrow(Self.batteryPowerModeCommand(mode))
    }

    /// True when `sudo -l` lists the exact password-less rule for the current user. Merely being permitted
    /// to run the command is not enough: an admin's password-requiring rule permits it too. Never prompts.
    public static func hasPasswordlessRule() -> Bool {
        listsRule(runCommand("/usr/bin/sudo", listRulesArguments))
    }

    /// Whether a `sudo -l` listing contains the rule that setup installs.
    public static func listsRule(_ listing: CommandResult) -> Bool {
        listing.status == 0 && listing.stdout.contains("NOPASSWD: " + ruleCommands)
    }

    private func runPrivilegedOrThrow(_ command: [String]) throws {
        let result = runPrivileged(command)
        guard result.status == 0 else {
            let setupRequired = Self.setupRequiredMarkers.contains { result.stderr.contains($0) }
            throw PowerError(kind: setupRequired ? .setupRequired : .commandFailed, detail: result.stderr.trimmed)
        }
    }

    /// `-k` is required: without it a sudo credential cached by an earlier `sudo` in the same terminal
    /// would let the command succeed with no rule installed, and a later `off` would then fail.
    private func runPrivileged(_ command: [String]) -> CommandResult {
        runCommand("/usr/bin/sudo", ["-k", "-n"] + command)
    }
}

/// A property of IOPMrootDomain, the kernel's power-management root object.
func rootDomainProperty(_ key: String) -> Any? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }
    return IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
}

public enum PowerSource {
    /// True on AC, and true on a machine without a battery.
    public static func isOnAC() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    /// Calls `handler` on the main queue whenever the providing power source changes, for the life of
    /// the process. Event based, no polling.
    public static func observeChanges(_ handler: @escaping () -> Void) {
        var token: Int32 = 0
        notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { _ in handler() }
    }
}

public enum Lid {
    /// `AppleClamshellState` on IOPMrootDomain (a public key in IOKit/pwr_mgt/IOPM.h).
    public static func isClosed() -> Bool {
        (rootDomainProperty("AppleClamshellState") as? Bool) ?? false
    }

    /// Calls `handler(closed)` on the main queue on every lid change, for the life of the process.
    /// Event based: the kernel's clamshell message (IOKit/pwr_mgt/IOPM.h), no polling.
    public static func observeChanges(_ handler: @escaping (Bool) -> Void) {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return }
        let context = Unmanaged.passRetained(Handler(handler)).toOpaque()  // lives as long as the process
        var notifier: io_object_t = 0
        IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, messageType, argument in
            guard messageType == Lid.clamshellMessage, let context else { return }
            // Bit 0 of the argument is kClamshellStateBit: 1 = closed.
            let closed = (UInt(bitPattern: argument) & 1) != 0
            Unmanaged<Handler>.fromOpaque(context).takeUnretainedValue().handler(closed)
        }, context, &notifier)
    }

    /// kIOPMMessageClamshellStateChange is a C macro Swift cannot import. Its value is fixed by the
    /// IOKit error-code layout (verified with clang against the SDK).
    private static let clamshellMessage: UInt32 = 0xE003_4100

    private final class Handler {
        let handler: (Bool) -> Void
        init(_ handler: @escaping (Bool) -> Void) { self.handler = handler }
    }
}

/// One diagnostic sample of what the machine is doing while keep-awake is on.
public struct Sample {
    public var lidClosed: Bool
    public var onAC: Bool
    public var batteryPercent: Int?
    /// From the battery pack itself (AppleSmartBatteryPack, BatteryData.Temperature in hundredths of a degree).
    public var batteryTemperatureC: Double?
    /// macOS thermal pressure: nominal, fair, serious or critical (ProcessInfo.thermalState).
    public var thermalState: String
    public var loadAverage: Double
    public var lowPowerMode: Bool

    public init(lidClosed: Bool, onAC: Bool, batteryPercent: Int?, batteryTemperatureC: Double?,
                thermalState: String, loadAverage: Double, lowPowerMode: Bool) {
        self.lidClosed = lidClosed
        self.onAC = onAC
        self.batteryPercent = batteryPercent
        self.batteryTemperatureC = batteryTemperatureC
        self.thermalState = thermalState
        self.loadAverage = loadAverage
        self.lowPowerMode = lowPowerMode
    }

    /// One log line, e.g. `lid=closed power=battery battery=83% batteryTemp=31.2C thermal=nominal load=1.42 energy=low`.
    public var text: String {
        let percent = batteryPercent.map { "\($0)%" } ?? "n/a"
        let temperature = batteryTemperatureC.map { String(format: "%.1fC", $0) } ?? "n/a"
        return "lid=\(lidClosed ? "closed" : "open") power=\(onAC ? "ac" : "battery") battery=\(percent) "
            + "batteryTemp=\(temperature) thermal=\(thermalState) load=\(String(format: "%.2f", loadAverage)) "
            + "energy=\(lowPowerMode ? "low" : "normal")"
    }
}

public enum Diagnostics {
    public static func sample() -> Sample {
        var load = [Double](repeating: 0, count: 1)
        getloadavg(&load, 1)
        let thermal: String
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: thermal = "nominal"
        case .fair: thermal = "fair"
        case .serious: thermal = "serious"
        case .critical: thermal = "critical"
        @unknown default: thermal = "unknown"
        }
        return Sample(lidClosed: Lid.isClosed(), onAC: PowerSource.isOnAC(), batteryPercent: batteryPercent(),
                      batteryTemperatureC: batteryTemperature(), thermalState: thermal, loadAverage: load[0],
                      lowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled)
    }

    /// `Current Capacity` of the first power source (documented IOPS key; percent on Macs).
    private static func batteryPercent() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef],
              let first = list.first,
              let description = IOPSGetPowerSourceDescription(info, first)?.takeUnretainedValue() as? [String: Any] else {
            return nil
        }
        return description[kIOPSCurrentCapacityKey] as? Int
    }

    /// The pack's "BatteryData" dictionary carries "Temperature" in hundredths of a degree Celsius.
    private static func batteryTemperature() -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let data = IORegistryEntryCreateCFProperty(service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        guard let raw = data?["Temperature"] as? Int else { return nil }
        return Double(raw) / 100
    }
}

// MARK: - Running child processes (shared with Setup and the CLI)

public struct CommandResult {
    public let status: Int32
    public let stdout: String
    public let stderr: String
}

/// Runs a program to completion with stdin closed. Both pipes are drained before waiting so the child
/// cannot block on a full pipe. Output is expected to be small (sudo, pmset, visudo, launchctl, open).
public func runCommand(_ path: String, _ arguments: [String]) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = arguments
    process.standardInput = FileHandle.nullDevice
    let stdout = Pipe()
    let stderr = Pipe()
    process.standardOutput = stdout
    process.standardError = stderr
    do {
        try process.run()
    } catch {
        return CommandResult(status: -1, stdout: "", stderr: "\(path): \(error.localizedDescription)")
    }
    let outData = stdout.fileHandleForReading.readDataToEndOfFile()
    let errData = stderr.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    var errorText = String(decoding: errData, as: UTF8.self)
    if errorText.trimmed.isEmpty && process.terminationStatus != 0 {
        // A child that dies by a signal or exits silently must still leave a readable error.
        errorText = process.terminationReason == .uncaughtSignal
            ? "\(path) terminated by signal \(process.terminationStatus)"
            : "\(path) exited with status \(process.terminationStatus)"
    }
    return CommandResult(status: process.terminationStatus,
                         stdout: String(decoding: outData, as: UTF8.self),
                         stderr: errorText)
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
