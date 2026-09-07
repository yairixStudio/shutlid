import os

/// The whole log, all interpolations public (otherwise `log show` prints `<private>`).
/// Category "events": on/off, settings, energy mode, failures. Category "samples": periodic diagnostics.
public enum Log {
    private static let logger = Logger(subsystem: Shutlid.logSubsystem, category: "events")
    private static let samples = Logger(subsystem: Shutlid.logSubsystem, category: "samples")

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
        logger.notice("settings changed: mode=\(settings.mode.rawValue, privacy: .public), autoOff=\(Status.autoOffText(hours: settings.autoOffHours), privacy: .public), restoreAfterRestart=\(settings.restoreAfterRestart, privacy: .public), lowPowerWhenClosed=\(settings.lowPowerText, privacy: .public)")
    }

    public static func lowPowerApplied(previous: Int) {
        logger.notice("energy mode: low (lid closed; was \(Status.energyModeText(previous), privacy: .public))")
    }

    public static func lowPowerRestored(to mode: Int) {
        logger.notice("energy mode: restored (\(Status.energyModeText(mode), privacy: .public))")
    }

    public static func lowPowerLeft() {
        logger.notice("energy mode: left as changed elsewhere")
    }

    public static func failure(_ detail: String) {
        logger.error("power operation failed: \(detail, privacy: .public)")
    }

    /// One line every few minutes while keep-awake is on; see Sample.text.
    public static func sample(_ text: String) {
        samples.notice("sample: \(text, privacy: .public)")
    }
}
