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
    /// The only place the privileged command is spelled. Setup builds the sudoers rule and the
    /// boot-reset plist from these two arrays.
    public static let enableCommand = ["/usr/bin/pmset", "disablesleep", "1"]
    public static let disableCommand = ["/usr/bin/pmset", "disablesleep", "0"]
    /// What a person types to reset the flag by hand when everything else failed.
    public static let manualResetCommand = "sudo pmset disablesleep 0"

    /// sudo prints one of these when no rule permits the command. The text is stable and not localised.
    private static let setupRequiredMarkers = ["a password is required", "not allowed", "may not run"]

    public init() {}

    public func isPreventingSleep() -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
        return (value as? Bool) ?? false
    }

    public func preventSleep(_ prevent: Bool) throws {
        let result = runPrivileged(prevent ? Self.enableCommand : Self.disableCommand)
        guard result.status == 0 else {
            let setupRequired = Self.setupRequiredMarkers.contains { result.stderr.contains($0) }
            throw PowerError(kind: setupRequired ? .setupRequired : .commandFailed, detail: result.stderr.trimmed)
        }
        guard isPreventingSleep() == prevent else {
            // Never leave the flag half-set: if enabling did not take, make sure it is off.
            if prevent { _ = runPrivileged(Self.disableCommand) }
            throw PowerError(kind: .commandFailed, detail: "kernel did not confirm")
        }
    }

    /// `-k` is required: without it a sudo credential cached by an earlier `sudo` in the same terminal
    /// would let the command succeed with no rule installed, and a later `off` would then fail.
    private func runPrivileged(_ command: [String]) -> CommandResult {
        runCommand("/usr/bin/sudo", ["-k", "-n"] + command)
    }
}

public enum PowerSource {
    /// True on AC, and true on a machine without a battery.
    public static func isOnAC() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return true }
        return (type as String) == kIOPMACPowerKey
    }

    /// Calls `handler` on the main queue whenever the providing power source changes. Event based, no polling.
    /// Returns the notify token; the caller keeps it for the life of the process.
    public static func observeChanges(_ handler: @escaping () -> Void) -> Int32 {
        var token: Int32 = 0
        notify_register_dispatch(kIOPSNotifyPowerSource, &token, .main) { _ in handler() }
        return token
    }
}

// MARK: - Running child processes (shared with Setup)

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

/// Runs a program to completion with stdin closed. Both pipes are drained before waiting so the child
/// cannot block on a full pipe. Output is expected to be small (sudo, pmset, visudo, launchctl).
func runCommand(_ path: String, _ arguments: [String]) -> CommandResult {
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
    return CommandResult(status: process.terminationStatus,
                         stdout: String(decoding: outData, as: UTF8.self),
                         stderr: String(decoding: errData, as: UTF8.self))
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
