import Foundation
import ShutlidCore

// The command line. Foundation only (no AppKit) so it starts fast and works over SSH.
// All state changes go through KeepAwake, exactly like the menu-bar app.

// Resolving symlinks turns /usr/local/bin/shutlid into the binary inside Shutlid.app.
let executable = Bundle.main.executableURL!.resolvingSymlinksInPath()
let ownPath = executable.path
/// Shutlid.app when this binary runs from inside it, else nil.
let bundlePath = Shutlid.bundlePath(ofCLI: ownPath)
/// Setup only works from inside the app, so point at the installed app when running from elsewhere.
let setupPath = bundlePath == nil ? Shutlid.installedCLIPath : ownPath

let usage = """
    Usage:
      shutlid on [--for <hours>]   keep the Mac awake, lid closed or not (--for: \(Command.forHoursRange.lowerBound)-\(Command.forHoursRange.upperBound), overrides Auto-off)
      shutlid off                  return to normal sleep
      shutlid status               show what was requested and what macOS is actually doing
      shutlid setup                one-time install of the privileged rule (run as root, see --help)
      shutlid log                  show the last day of Shutlid events from the unified log
      shutlid --version            print the version
      shutlid --help               print this help
    """

let helpText = """
    shutlid \(Shutlid.version) — keep a MacBook awake with the lid closed

    \(usage)

    Exit codes:
      on, off   0 = done   1 = error   2 = setup required
      status    0 = keeping awake (Effective: ON)   1 = normal sleep (Effective: OFF)
      others    0 = done   1 = error

    `on` exits 0 when the request was recorded and applied where the mode allows;
    read `status` for the effective state. Auto-off (default 24h) is enforced by
    \(Shutlid.appName).app, which `on` launches in the background.

    Setup (once, needs an administrator password; run from the installed app):
      sudo "\(setupPath)" setup

    Agent example:
      User:  Keep my Mac awake, I'm closing the lid.
      Agent: shutlid on
      ...
      User:  You can let it sleep now.
      Agent: shutlid off
    """

let keepAwake = KeepAwake()

func printError(_ text: String) {
    FileHandle.standardError.write(Data((text + "\n").utf8))
}

func printStatus() {
    print(keepAwake.status().cliText(now: Date()))
}

/// Prints the error and returns the exit code: 2 means "run setup", 1 anything else.
func report(_ error: Error) -> Int32 {
    if let power = error as? PowerError, power.kind == .setupRequired {
        printError("Setup required. Run once: sudo \"\(setupPath)\" setup")
        return 2
    }
    printError("error: \(error)")
    return 1
}

/// `open -g` starts the app in the background (or does nothing if it already runs) without stealing focus.
func launchApp() -> Bool {
    let result = runCommand("/usr/bin/open", bundlePath.map { ["-g", $0] } ?? ["-g", "-b", Shutlid.bundleIdentifier])
    if result.status != 0 { printError(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
    return result.status == 0
}

func turnOn(hours: Int?) -> Int32 {
    do {
        try keepAwake.turnOn(source: .cli, hours: hours)
    } catch {
        return report(error)
    }
    if launchApp() { return 0 }
    if keepAwake.status().deadline == nil {
        printError("warning: \(Shutlid.appName).app could not be launched; no auto-off was requested, continuing")
        return 0
    }
    // Only the app owns the auto-off timer: without it the deadline would never fire, so fail toward sleep.
    do {
        try keepAwake.turnOff(source: .cli)
    } catch {
        printError("error: \(error)")
    }
    printError("error: \(Shutlid.appName).app could not be launched; auto-off cannot be enforced")
    return 1
}

func turnOff() -> Int32 {
    do {
        try keepAwake.turnOff(source: .cli)
    } catch {
        return report(error)
    }
    return 0
}

func showLog() -> Never {
    let arguments = ["/usr/bin/log", "show", "--predicate", "subsystem == \"\(Shutlid.logSubsystem)\"",
                     "--last", "1d", "--style", "compact"]
    var argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
    execv(arguments[0], &argv)  // returns only on failure
    printError("error: could not run \(arguments[0]): \(String(cString: strerror(errno)))")
    exit(1)
}

let command: Command
switch Command.parse(Array(CommandLine.arguments.dropFirst())) {
case .success(let parsed):
    command = parsed
case .failure(let error):
    printError("error: \(error)\n\(usage)")
    exit(1)
}

// Root keeps its own preferences and needs no sudo rule, so `sudo shutlid on` would set the flag with
// nothing ever turning it off. Only setup runs as root.
switch command {
case .on, .off, .status:
    if getuid() == 0 {
        printError("error: run shutlid as your normal user, not with sudo; only 'setup' needs root")
        exit(1)
    }
default:
    break
}

switch command {
case .on(let hours):
    let code = turnOn(hours: hours)
    printStatus()
    exit(code)
case .off:
    let code = turnOff()
    printStatus()
    exit(code)
case .status:
    let status = keepAwake.status()
    print(status.cliText(now: Date()))
    exit(status.effective ? 0 : 1)
case .setup:
    do {
        try Setup.install(cliPath: ownPath)
    } catch {
        printError(String(describing: error))
        // Without root the message is the sudo instruction; 2 means "run setup" everywhere in this CLI.
        exit(getuid() == 0 ? 1 : 2)
    }
case .log:
    showLog()
case .version:
    print("shutlid \(Shutlid.version)")
case .help:
    print(helpText)
}
