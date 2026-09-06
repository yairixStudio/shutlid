import Foundation

public struct SetupError: Error, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}

/// One-time root install of the three files that let the app and the CLI toggle sleep without a password:
/// the scoped sudoers rule, the boot-time reset daemon and the CLI symlink. Re-runnable.
public enum Setup {
    private static let sudoersTempPath = "/etc/sudoers.d/.shutlid.tmp"  // dotted names are ignored by sudo
    private static let cliPathSuffix = ".app/Contents/MacOS/shutlid"

    public static var sudoersLine: String {
        "%admin ALL=(root) NOPASSWD: " + PowerController.enableCommand.joined(separator: " ")
            + ", " + PowerController.disableCommand.joined(separator: " ")
    }

    public static func resetDaemonPlist() -> String {
        let arguments = PowerController.disableCommand.map { "        <string>\($0)</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(Shutlid.resetDaemonLabel)</string>
            <key>ProgramArguments</key>
            <array>
        \(arguments)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>AssociatedBundleIdentifiers</key>
            <array>
                <string>\(Shutlid.bundleIdentifier)</string>
            </array>
        </dict>
        </plist>

        """
    }

    /// True when the current user may run the enable command without a password. Never prompts (`-n`).
    public static func isInstalled() -> Bool {
        runCommand("/usr/bin/sudo", ["-k", "-n", "-l"] + PowerController.enableCommand).status == 0
    }

    /// Must run as root from the CLI inside Shutlid.app. Prints each installed path; never reads a password.
    public static func install(cliPath: String) throws {
        guard cliPath.hasSuffix(cliPathSuffix) else {
            throw SetupError("run setup from the shutlid binary inside \(Shutlid.appName).app")
        }
        guard getuid() == 0 else {
            throw SetupError("Run: sudo \"\(cliPath)\" setup")
        }
        // Three parents up from Shutlid.app/Contents/MacOS/shutlid is the bundle.
        let bundleURL = URL(fileURLWithPath: cliPath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        if !bundleURL.path.hasPrefix("/Applications/") {
            print("warning: \(Shutlid.appName).app is not in /Applications; moving it later means running setup again.")
        }
        try installSudoers()
        try installResetDaemon()
        try installSymlink(cliPath: cliPath)
        verifyAsInvokingUser()
    }

    /// Written, owned, validated and only then renamed into place, all inside /etc/sudoers.d.
    private static func installSudoers() throws {
        do {
            try (sudoersLine + "\n").write(toFile: sudoersTempPath, atomically: false, encoding: .utf8)
            try own(sudoersTempPath, mode: 0o440)
            let check = runCommand("/usr/sbin/visudo", ["-cf", sudoersTempPath])
            guard check.status == 0 else {
                throw SetupError("visudo rejected the sudoers rule: \((check.stderr + check.stdout).trimmed)")
            }
            guard rename(sudoersTempPath, Shutlid.sudoersPath) == 0 else {
                throw SetupError("could not install \(Shutlid.sudoersPath): \(errnoText())")
            }
        } catch {
            unlink(sudoersTempPath)
            throw error
        }
        print("installed \(Shutlid.sudoersPath)")
    }

    private static func installResetDaemon() throws {
        let flagWasOn = PowerController().isPreventingSleep()
        try resetDaemonPlist().write(toFile: Shutlid.resetDaemonPath, atomically: true, encoding: .utf8)
        try own(Shutlid.resetDaemonPath, mode: 0o644)
        _ = runCommand("/bin/launchctl", ["bootout", "system/\(Shutlid.resetDaemonLabel)"])
        let bootstrap = runCommand("/bin/launchctl", ["bootstrap", "system", Shutlid.resetDaemonPath])
        guard bootstrap.status == 0 else {
            throw SetupError("launchctl bootstrap failed: \((bootstrap.stderr + bootstrap.stdout).trimmed)")
        }
        print("installed \(Shutlid.resetDaemonPath)")
        if flagWasOn {
            // RunAtLoad just ran the disable command.
            print("note: keep-awake was reset to normal sleep; run 'shutlid on' again.")
        }
    }

    private static func installSymlink(cliPath: String) throws {
        let files = FileManager.default
        let binDir = (Shutlid.cliSymlinkPath as NSString).deletingLastPathComponent
        if !files.fileExists(atPath: binDir) {
            try files.createDirectory(atPath: binDir, withIntermediateDirectories: true)
            try own(binDir, mode: 0o755)
        }
        // attributesOfItem does not follow symlinks, so an existing link is seen as a link.
        if let attributes = try? files.attributesOfItem(atPath: Shutlid.cliSymlinkPath) {
            guard attributes[.type] as? FileAttributeType == .typeSymbolicLink else {
                throw SetupError("\(Shutlid.cliSymlinkPath) exists and is not a symlink; remove it and run setup again")
            }
            try files.removeItem(atPath: Shutlid.cliSymlinkPath)
        }
        try files.createSymbolicLink(atPath: Shutlid.cliSymlinkPath, withDestinationPath: cliPath)
        print("installed \(Shutlid.cliSymlinkPath) -> \(cliPath)")
    }

    /// The rule is for %admin, so check it as the person who ran sudo, not as root. Warns, never rolls back.
    private static func verifyAsInvokingUser() {
        let consoleUser = runCommand("/usr/bin/stat", ["-f%Su", "/dev/console"]).stdout.trimmed
        let user = ProcessInfo.processInfo.environment["SUDO_USER"] ?? consoleUser
        let listArguments = ["-k", "-n", "-l"] + PowerController.enableCommand
        let check = runCommand("/usr/bin/sudo", ["-u", user, "/usr/bin/sudo"] + listArguments)
        if check.status == 0 {
            print("Setup complete.")
        } else {
            print("warning: could not confirm the sudo rule for \(user). Check by hand as that user: sudo \(listArguments.joined(separator: " "))")
        }
    }

    private static func own(_ path: String, mode: mode_t) throws {
        guard chown(path, 0, 0) == 0, chmod(path, mode) == 0 else {
            throw SetupError("could not set owner and mode of \(path): \(errnoText())")
        }
    }

    private static func errnoText() -> String {
        String(cString: strerror(errno))
    }
}
