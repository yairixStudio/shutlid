/// Project-wide constants. Everything that names a file, an identifier or a version lives here.
public enum Shutlid {
    public static let bundleIdentifier = "com.yairix.shutlid"
    /// Must differ from the bundle identifier: a suite named after the bundle id resolves to nil.
    public static let defaultsSuite = "com.yairix.shutlid.state"
    public static let version = "1.0.0"
    public static let changedNotification = "com.yairix.shutlid.changed"
    public static let logSubsystem = "com.yairix.shutlid"
    public static let sudoersPath = "/etc/sudoers.d/shutlid"
    public static let resetDaemonLabel = "com.yairix.shutlid.reset"
    public static let resetDaemonPath = "/Library/LaunchDaemons/com.yairix.shutlid.reset.plist"
    public static let cliSymlinkPath = "/usr/local/bin/shutlid"
    public static let appName = "Shutlid"
}
