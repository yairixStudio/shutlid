import ShutlidCore

/// In-memory stand-in for UserDefaults: no cfprefsd, no files, safe under `swift test --parallel`.
final class MemoryStore: Store {
    private var values: [String: Any] = [:]

    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values[key] = nil }
}

/// Stands in for the kernel flag and the battery Energy Mode. Records every call, can throw, can lie.
final class FakePower: PowerControlling {
    var flag = false
    /// When set, isPreventingSleep reports this instead of the real flag.
    var reportedFlag: Bool?
    /// When set, preventSleep throws it (after recording the call) and leaves the flag alone.
    var error: Error?
    private(set) var calls: [Bool] = []

    /// The battery Energy Mode "on the Mac"; nil = unreadable. Defaults to high power, like the test Mac.
    var batteryMode: Int? = 2
    var modeError: Error?
    private(set) var modeCalls: [Int] = []

    func isPreventingSleep() -> Bool {
        reportedFlag ?? flag
    }

    func preventSleep(_ prevent: Bool) throws {
        calls.append(prevent)
        if let error { throw error }
        flag = prevent
    }

    func batteryPowerMode() -> Int? {
        batteryMode
    }

    func setBatteryPowerMode(_ mode: Int) throws {
        modeCalls.append(mode)
        if let modeError { throw modeError }
        batteryMode = mode
    }
}
