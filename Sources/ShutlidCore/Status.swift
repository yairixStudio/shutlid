import Foundation

/// A snapshot: what was asked for, what the kernel is doing, and the settings that explain any difference.
public struct Status {
    public let requested: Bool
    public let effective: Bool
    public let mode: Mode
    public let onAC: Bool
    public let deadline: Date?
    public let autoOffHours: Int

    public init(requested: Bool, effective: Bool, mode: Mode, onAC: Bool, deadline: Date?, autoOffHours: Int) {
        self.requested = requested
        self.effective = effective
        self.mode = mode
        self.onAC = onAC
        self.deadline = deadline
        self.autoOffHours = autoOffHours
    }

    /// Requested-and-waiting-for-power counts as on: the menu offers "Turn Off".
    public var isOnLike: Bool {
        effective || waitingForPower
    }

    private var waitingForPower: Bool {
        requested && !effective && mode == .onlyOnPower && !onAC
    }

    /// Exactly four lines, labels padded to 12 columns, no trailing newline.
    public func cliText(now: Date) -> String {
        let effectiveText: String
        if waitingForPower {
            effectiveText = "OFF (on battery; mode: only while connected to power)"
        } else if requested && !effective {
            effectiveText = "OFF (not applied; run 'shutlid on' again)"
        } else if !requested && effective {
            effectiveText = "ON (turn-off failed; run: \(PowerController.manualResetCommand))"
        } else {
            effectiveText = effective ? "ON" : "OFF"
        }
        let modeText = mode == .always ? "always" : "only while connected to power"
        return [
            line("Requested:", requested ? "ON" : "OFF"),
            line("Effective:", effectiveText),
            line("Mode:", modeText),
            line("Auto-off:", autoOffLine(now: now)),
        ].joined(separator: "\n")
    }

    public func menuTitle(now: Date) -> String {
        if effective {
            guard let deadline else { return "● Keeping awake — no auto-off" }
            if deadline > now { return "● Keeping awake — auto-off in \(Self.remainingText(until: deadline, now: now))" }
            return "● Keeping awake — auto-off expired"
        }
        if waitingForPower { return "◐ On battery — keeps awake when plugged in" }
        return "○ Normal sleep"
    }

    /// "under 1m", "59m", "1h 0m", "23h 59m". Only called with a future `until`.
    public static func remainingText(until: Date, now: Date) -> String {
        let seconds = until.timeIntervalSince(now)
        if seconds < 60 { return "under 1m" }
        let minutes = Int(seconds / 60)
        let hours = minutes / 60
        if hours > 0 { return "\(hours)h \(minutes % 60)m" }
        return "\(minutes)m"
    }

    /// "24h", or "never" for 0. Used by the status text, the menu and the log.
    public static func autoOffText(hours: Int) -> String {
        hours == 0 ? "never" : "\(hours)h"
    }

    private func autoOffLine(now: Date) -> String {
        guard let deadline else { return Self.autoOffText(hours: autoOffHours) }
        if deadline > now { return "in \(Self.remainingText(until: deadline, now: now))" }
        return "expired"
    }

    private func line(_ label: String, _ value: String) -> String {
        label.padding(toLength: 12, withPad: " ", startingAt: 0) + value
    }
}
