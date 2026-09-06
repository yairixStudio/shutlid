/// CLI argument parsing. Pure: no I/O, no process state.
public enum Command: Equatable {
    case on(hours: Int?)
    case off
    case status
    case setup
    case log
    case version
    case help

    public static let forHoursRange = 1...720

    /// The message to print before the usage text.
    public static func parse(_ arguments: [String]) -> Result<Command, UsageError> {
        guard let name = arguments.first else { return .failure(UsageError("missing command")) }
        let rest = Array(arguments.dropFirst())
        if name == "on" { return parseOn(rest) }
        let simple: Command
        switch name {
        case "off": simple = .off
        case "status": simple = .status
        case "setup": simple = .setup
        case "log": simple = .log
        case "--version", "version": simple = .version
        case "--help", "help", "-h": simple = .help
        default: return .failure(UsageError("unknown command '\(name)'"))
        }
        guard rest.isEmpty else { return .failure(UsageError("'\(name)' takes no arguments")) }
        return .success(simple)
    }

    private static func parseOn(_ rest: [String]) -> Result<Command, UsageError> {
        if rest.isEmpty { return .success(.on(hours: nil)) }
        guard rest.count == 2, rest[0] == "--for" else { return .failure(UsageError("usage: shutlid on [--for <hours>]")) }
        guard let hours = Int(rest[1]), forHoursRange.contains(hours) else {
            return .failure(UsageError("--for expects a whole number of hours from \(forHoursRange.lowerBound) to \(forHoursRange.upperBound)"))
        }
        return .success(.on(hours: hours))
    }
}

public struct UsageError: Error, Equatable, CustomStringConvertible {
    public let description: String

    public init(_ description: String) {
        self.description = description
    }
}
