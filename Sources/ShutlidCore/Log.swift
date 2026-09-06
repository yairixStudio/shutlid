import os

/// The whole log: five event kinds, all interpolations public (otherwise `log show` prints `<private>`).
public enum Log {
    private static let logger = Logger(subsystem: Shutlid.logSubsystem, category: "events")

    /// `autoOff` is "24h", "never" or "in 3h 10m". `deferred` = requested on battery in power-only mode.
    public static func turnedOn(source: Source, autoOff: String, deferred: Bool) {
        if deferred {
            logger.notice("turned on (source: \(source.rawValue, privacy: .public), auto-off: \(autoOff, privacy: .public), waiting for power)")
        } else {
            logger.notice("turned on (source: \(source.rawValue, privacy: .public), auto-off: \(autoOff, privacy: .public))")
        }
    }

    public static func turnedOff(source: Source) {
        logger.notice("turned off (source: \(source.rawValue, privacy: .public))")
    }

    public static func settingsChanged(_ settings: Settings) {
        logger.notice("settings changed: mode=\(settings.mode.rawValue, privacy: .public), autoOff=\(autoOffText(hours: settings.autoOffHours), privacy: .public), restoreAfterRestart=\(settings.restoreAfterRestart, privacy: .public)")
    }

    public static func failure(_ detail: String) {
        logger.error("power operation failed: \(detail, privacy: .public)")
    }

    static func autoOffText(hours: Int) -> String {
        hours == 0 ? "never" : "\(hours)h"
    }
}
