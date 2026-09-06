import ShutlidCore

/// Stands in for the kernel flag. Records every preventSleep call, can throw, and can lie about the flag.
final class FakePower: PowerControlling {
    var flag = false
    /// When set, isPreventingSleep reports this instead of the real flag.
    var reportedFlag: Bool?
    /// When set, preventSleep throws it (after recording the call) and leaves the flag alone.
    var error: Error?
    private(set) var calls: [Bool] = []

    func isPreventingSleep() -> Bool {
        reportedFlag ?? flag
    }

    func preventSleep(_ prevent: Bool) throws {
        calls.append(prevent)
        if let error { throw error }
        flag = prevent
    }
}
