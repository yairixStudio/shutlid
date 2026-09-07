import XCTest
@testable import ShutlidCore

final class KeepAwakeTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)
    private var onAC = true
    private var lidClosed = false
    private var setupInstalled = true
    private var store: MemoryStore!
    private var bootSession = "boot-A"
    private var power: FakePower!
    private var keepAwake: KeepAwake!

    private let commandFailed = PowerError(kind: .commandFailed, detail: "boom")
    private let setupRequired = PowerError(kind: .setupRequired, detail: "a password is required")

    override func setUp() {
        super.setUp()
        power = FakePower()
        store = MemoryStore()
        clock = start
        onAC = true
        lidClosed = false
        setupInstalled = true
        bootSession = "boot-A"
        keepAwake = KeepAwake(power: power, defaults: store,
                              isOnAC: { [unowned self] in onAC },
                              isLidClosed: { [unowned self] in lidClosed },
                              isSetupInstalled: { [unowned self] in setupInstalled },
                              bootSession: { [unowned self] in bootSession },
                              now: { [unowned self] in clock })
    }

    private func hours(_ hours: Double, from date: Date? = nil) -> Date {
        (date ?? start).addingTimeInterval(hours * 3600)
    }

    /// Simulates a restart: the boot reset cleared the flag and the boot session is new.
    private func reboot() {
        power.flag = false
        bootSession = "boot-B"
    }

    // MARK: - turnOn

    func testTurnOnRecordsRequestWithDefaultDeadline() throws {
        try keepAwake.turnOn(source: .cli)
        let status = keepAwake.status()
        XCTAssertTrue(status.requested)
        XCTAssertTrue(status.effective)
        XCTAssertEqual(status.deadline, hours(24))
        XCTAssertEqual(power.calls, [true])
    }

    func testTurnOnForOverridesDeadline() throws {
        try keepAwake.turnOn(source: .cli, hours: 4)
        XCTAssertEqual(keepAwake.status().deadline, hours(4))
        XCTAssertEqual(keepAwake.settings.autoOffHours, 24, "--for does not change the setting")
    }

    func testTurnOnNeverHasNoDeadline() throws {
        keepAwake.settings.autoOffHours = 0
        try keepAwake.turnOn(source: .gui)
        XCTAssertTrue(keepAwake.status().requested)
        XCTAssertNil(keepAwake.status().deadline)
    }

    func testSecondTurnOnResetsDeadline() throws {
        try keepAwake.turnOn(source: .cli)
        clock = hours(1)
        try keepAwake.turnOn(source: .cli, hours: 8)
        XCTAssertEqual(keepAwake.status().deadline, hours(8, from: clock))
    }

    func testTurnOnFailureWhileOnLeavesStateUnchanged() throws {
        try keepAwake.turnOn(source: .cli, hours: 4)
        clock = hours(1)
        power.error = commandFailed
        XCTAssertThrowsError(try keepAwake.turnOn(source: .cli))
        let status = keepAwake.status()
        XCTAssertTrue(status.requested)
        XCTAssertEqual(status.deadline, hours(4))
    }

    func testTurnOnFailureWhileOffStaysOff() {
        power.error = commandFailed
        XCTAssertThrowsError(try keepAwake.turnOn(source: .cli))
        let status = keepAwake.status()
        XCTAssertFalse(status.requested)
        XCTAssertFalse(status.effective)
        XCTAssertNil(status.deadline)
    }

    func testTurnOnDeferredOnBatteryWithoutSetupThrows() {
        keepAwake.settings.mode = .onlyOnPower
        onAC = false
        setupInstalled = false
        XCTAssertThrowsError(try keepAwake.turnOn(source: .cli)) { error in
            XCTAssertEqual((error as? PowerError)?.kind, .setupRequired)
        }
        XCTAssertEqual(power.calls, [])
        XCTAssertFalse(keepAwake.status().requested)
    }

    func testTurnOnDeferredOnBatteryWithSetupRecordsRequest() throws {
        keepAwake.settings.mode = .onlyOnPower
        onAC = false
        try keepAwake.turnOn(source: .cli)
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [], "the flag is not touched on battery")
        XCTAssertTrue(status.requested)
        XCTAssertFalse(status.effective)
        XCTAssertEqual(status.deadline, hours(24))
    }

    // MARK: - turnOff

    func testTurnOffAlwaysRunsDisableEvenWhenOff() throws {
        try keepAwake.turnOff(source: .cli)
        XCTAssertEqual(power.calls, [false])
        XCTAssertFalse(keepAwake.status().requested)
    }

    func testTurnOffClearsRequestAndDeadline() throws {
        try keepAwake.turnOn(source: .gui)
        try keepAwake.turnOff(source: .gui)
        let status = keepAwake.status()
        XCTAssertFalse(status.requested)
        XCTAssertFalse(status.effective)
        XCTAssertNil(status.deadline)
        XCTAssertEqual(power.calls, [true, false])
    }

    func testTurnOffFailureClearsRequestAndDeadline() throws {
        try keepAwake.turnOn(source: .cli)
        power.error = commandFailed
        XCTAssertThrowsError(try keepAwake.turnOff(source: .cli))
        let status = keepAwake.status()
        XCTAssertFalse(status.requested)
        XCTAssertTrue(status.effective, "the kernel flag is still set; the status text says so")
        XCTAssertNil(status.deadline)
    }

    func testTurnOffSetupRequiredWithFlagOffSucceeds() throws {
        power.error = setupRequired
        try keepAwake.turnOff(source: .cli)
        XCTAssertEqual(power.calls, [false])
        XCTAssertFalse(keepAwake.status().requested)
    }

    func testTurnOffSetupRequiredWithFlagOnThrows() throws {
        try keepAwake.turnOn(source: .cli)
        power.error = setupRequired
        XCTAssertThrowsError(try keepAwake.turnOff(source: .cli))
        XCTAssertTrue(keepAwake.status().effective)
    }

    // MARK: - Power mode

    func testFlagShouldBeOnTruthTable() {
        typealias Row = (requested: Bool, mode: Mode, onAC: Bool, expected: Bool)
        let rows: [Row] = [
            (true, .always, true, true), (true, .always, false, true),
            (true, .onlyOnPower, true, true), (true, .onlyOnPower, false, false),
            (false, .always, true, false), (false, .always, false, false),
            (false, .onlyOnPower, true, false), (false, .onlyOnPower, false, false),
        ]
        for row in rows {
            XCTAssertEqual(KeepAwake.flagShouldBeOn(requested: row.requested, mode: row.mode, onAC: row.onAC),
                           row.expected, "\(row)")
        }
    }

    func testPowerSourceChangedOnlyOnPowerBatteryRemovesFlagAndKeepsDeadline() throws {
        keepAwake.settings.mode = .onlyOnPower
        try keepAwake.turnOn(source: .cli, hours: 4)
        onAC = false
        try keepAwake.powerSourceChanged()
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true, false])
        XCTAssertFalse(status.effective)
        XCTAssertTrue(status.requested)
        XCTAssertEqual(status.deadline, hours(4))
    }

    func testPowerSourceChangedOnlyOnPowerACAppliesFlag() throws {
        keepAwake.settings.mode = .onlyOnPower
        onAC = false
        try keepAwake.turnOn(source: .cli)
        onAC = true
        try keepAwake.powerSourceChanged()
        XCTAssertEqual(power.calls, [true])
        XCTAssertTrue(keepAwake.status().effective)
    }

    func testPowerSourceChangedAlwaysNeverTouchesFlag() throws {
        try keepAwake.turnOn(source: .cli)
        power.flag = false  // cleared by hand with pmset: not ours to re-apply
        onAC = false
        try keepAwake.powerSourceChanged()
        onAC = true
        try keepAwake.powerSourceChanged()
        XCTAssertEqual(power.calls, [true])
    }

    func testPowerSourceChangedDoesNothingWhenNotRequested() throws {
        keepAwake.settings.mode = .onlyOnPower
        onAC = false
        try keepAwake.powerSourceChanged()
        onAC = true
        try keepAwake.powerSourceChanged()
        XCTAssertEqual(power.calls, [])
    }

    func testSettingsModeChangeWhileOnOnBatteryRemovesFlag() throws {
        onAC = false
        try keepAwake.turnOn(source: .gui)
        keepAwake.settings.mode = .onlyOnPower
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true, false])
        XCTAssertTrue(status.requested)
        XCTAssertFalse(status.effective)
        XCTAssertEqual(status.deadline, hours(24))
    }

    func testSettingsModeChangeToAlwaysWhileWaitingAppliesFlag() throws {
        keepAwake.settings.mode = .onlyOnPower
        onAC = false
        try keepAwake.turnOn(source: .gui)
        keepAwake.settings.mode = .always
        XCTAssertEqual(power.calls, [true])
        XCTAssertTrue(keepAwake.status().effective)
    }

    // MARK: - Settings

    func testSettingsAutoOffChangeWhileOnRestartsCountdown() throws {
        try keepAwake.turnOn(source: .gui)
        clock = hours(2)
        keepAwake.settings.autoOffHours = 4
        XCTAssertEqual(keepAwake.status().deadline, hours(4, from: clock))
    }

    func testSettingsAutoOffNeverClearsDeadline() throws {
        try keepAwake.turnOn(source: .gui)
        keepAwake.settings.autoOffHours = 0
        XCTAssertNil(keepAwake.status().deadline)
        XCTAssertTrue(keepAwake.status().requested)
    }

    func testSettingsAutoOffChangeWhileOffSetsNoDeadline() {
        keepAwake.settings.autoOffHours = 1
        XCTAssertNil(keepAwake.status().deadline)
        XCTAssertEqual(keepAwake.settings.autoOffHours, 1)
    }

    func testSettingsWriteWithSameAutoOffKeepsDeadline() throws {
        try keepAwake.turnOn(source: .gui)
        clock = hours(1)
        keepAwake.settings.restoreAfterRestart = true
        XCTAssertEqual(keepAwake.status().deadline, hours(24))
    }

    func testSettingsDefaults() {
        XCTAssertEqual(keepAwake.settings, Settings(mode: .always, autoOffHours: 24, restoreAfterRestart: false))
    }

    // MARK: - applyAtLaunch

    func testApplyAtLaunchExpiredTurnsOff() throws {
        try keepAwake.turnOn(source: .cli, hours: 1)
        clock = hours(2)
        try keepAwake.applyAtLaunch()
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true, false])
        XCTAssertFalse(status.requested)
        XCTAssertFalse(status.effective)
        XCTAssertNil(status.deadline)
    }

    func testApplyAtLaunchExpiredWinsOverRestore() throws {
        keepAwake.settings.restoreAfterRestart = true
        try keepAwake.turnOn(source: .cli, hours: 1)
        reboot()
        clock = hours(2)
        try keepAwake.applyAtLaunch()
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true, false], "an expired request is not restored")
        XCTAssertFalse(status.requested)
        XCTAssertNil(status.deadline)
    }

    func testApplyAtLaunchAfterRebootRestoreOnReappliesWithFreshDeadline() throws {
        keepAwake.settings.restoreAfterRestart = true
        try keepAwake.turnOn(source: .cli, hours: 4)
        reboot()
        clock = hours(1)
        try keepAwake.applyAtLaunch()
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true, true])
        XCTAssertTrue(status.requested)
        XCTAssertTrue(status.effective)
        XCTAssertEqual(status.deadline, hours(24, from: clock))
    }

    func testApplyAtLaunchAfterRebootRestoreOnDefersOnBattery() throws {
        keepAwake.settings = Settings(mode: .onlyOnPower, autoOffHours: 8, restoreAfterRestart: true)
        try keepAwake.turnOn(source: .cli)
        reboot()
        onAC = false
        clock = hours(1)
        try keepAwake.applyAtLaunch()
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true])
        XCTAssertTrue(status.requested)
        XCTAssertFalse(status.effective)
        XCTAssertEqual(status.deadline, hours(8, from: clock))
    }

    func testApplyAtLaunchAfterRebootRestoreOffClearsStaleRequest() throws {
        try keepAwake.turnOn(source: .cli)
        reboot()
        try keepAwake.applyAtLaunch()
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true], "nothing is re-applied and nothing is released")
        XCTAssertFalse(status.requested)
        XCTAssertNil(status.deadline)
    }

    func testApplyAtLaunchAfterRebootOnBatteryPowerOnlyClearsStaleRequest() throws {
        keepAwake.settings.mode = .onlyOnPower
        try keepAwake.turnOn(source: .cli)
        reboot()
        onAC = false
        try keepAwake.applyAtLaunch()
        XCTAssertEqual(power.calls, [true])
        XCTAssertFalse(keepAwake.status().requested, "a stale request must not survive a reboot in power-only mode")
    }

    func testApplyAtLaunchSameBootKeepsDeferredRequest() throws {
        // `shutlid on` on battery in power-only mode launches the app; the app must not treat the deferred
        // request as a stale one.
        keepAwake.settings.mode = .onlyOnPower
        onAC = false
        try keepAwake.turnOn(source: .cli, hours: 4)
        try keepAwake.applyAtLaunch()
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [])
        XCTAssertTrue(status.requested)
        XCTAssertEqual(status.deadline, hours(4))
        onAC = true
        try keepAwake.powerSourceChanged()
        XCTAssertEqual(power.calls, [true])
    }

    func testApplyAtLaunchSameBootManualResetClearsRequest() throws {
        try keepAwake.turnOn(source: .cli)
        power.flag = false  // `sudo pmset disablesleep 0` by hand, then the app relaunched
        try keepAwake.applyAtLaunch()
        XCTAssertEqual(power.calls, [true])
        XCTAssertFalse(keepAwake.status().requested)
    }

    func testApplyAtLaunchCrashCaseUntouched() throws {
        try keepAwake.turnOn(source: .cli, hours: 4)
        clock = hours(1)
        try keepAwake.applyAtLaunch()
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true])
        XCTAssertTrue(status.requested)
        XCTAssertTrue(status.effective)
        XCTAssertEqual(status.deadline, hours(4))
    }

    func testApplyAtLaunchCrashCasePowerOnlyNowOnBatteryRemovesFlag() throws {
        keepAwake.settings.mode = .onlyOnPower
        try keepAwake.turnOn(source: .cli, hours: 4)
        onAC = false  // unplugged while the app was dead
        try keepAwake.applyAtLaunch()
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true, false])
        XCTAssertTrue(status.requested)
        XCTAssertFalse(status.effective)
        XCTAssertEqual(status.deadline, hours(4))
    }

    func testApplyAtLaunchNotRequestedDoesNothing() throws {
        power.flag = true  // set by something else; not ours to reconcile
        try keepAwake.applyAtLaunch()
        XCTAssertEqual(power.calls, [])
        XCTAssertFalse(keepAwake.status().requested)
    }

    // MARK: - releaseForTermination

    func testReleaseForTerminationUserInitiatedClears() throws {
        keepAwake.settings.restoreAfterRestart = true
        try keepAwake.turnOn(source: .gui)
        try keepAwake.releaseForTermination(userInitiated: true)
        let status = keepAwake.status()
        XCTAssertFalse(status.effective)
        XCTAssertFalse(status.requested)
        XCTAssertNil(status.deadline)
    }

    func testReleaseForTerminationSystemRestoreOffClears() throws {
        try keepAwake.turnOn(source: .gui)
        try keepAwake.releaseForTermination(userInitiated: false)
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true, false])
        XCTAssertFalse(status.effective)
        XCTAssertFalse(status.requested)
        XCTAssertNil(status.deadline)
    }

    func testReleaseForTerminationSystemRestoreOnKeepsRequest() throws {
        keepAwake.settings.restoreAfterRestart = true
        try keepAwake.turnOn(source: .gui, hours: 4)
        try keepAwake.releaseForTermination(userInitiated: false)
        let status = keepAwake.status()
        XCTAssertEqual(power.calls, [true, false])
        XCTAssertFalse(status.effective)
        XCTAssertTrue(status.requested)
        XCTAssertEqual(status.deadline, hours(4))
    }

    func testReleaseForTerminationSystemWithFlagOffDoesNotTouchPower() throws {
        keepAwake.settings.mode = .onlyOnPower
        onAC = false
        try keepAwake.turnOn(source: .gui)
        try keepAwake.releaseForTermination(userInitiated: false)
        XCTAssertEqual(power.calls, [])
        XCTAssertFalse(keepAwake.status().requested)
    }

    // MARK: - Low Power Mode while the lid is closed

    /// Turn on, close the lid, sync: the common path.
    private func closeLidWhileOn() throws {
        try keepAwake.turnOn(source: .cli)
        lidClosed = true
        try keepAwake.syncLowPower()
    }

    func testLidCloseWhileOnSwitchesToLowPower() throws {
        try closeLidWhileOn()
        XCTAssertEqual(power.modeCalls, [1])
        XCTAssertEqual(power.batteryMode, 1)
        XCTAssertEqual(keepAwake.status().lowPowerRestoresTo, 2)
    }

    func testLidOpenRestoresPreviousMode() throws {
        try closeLidWhileOn()
        lidClosed = false
        try keepAwake.syncLowPower()
        XCTAssertEqual(power.modeCalls, [1, 2])
        XCTAssertEqual(power.batteryMode, 2)
        XCTAssertNil(keepAwake.status().lowPowerRestoresTo)
    }

    func testLidCloseWhileOffDoesNothing() throws {
        lidClosed = true
        try keepAwake.syncLowPower()
        XCTAssertEqual(power.modeCalls, [])
    }

    func testLidCloseWhenAlreadyLowPowerRemembersNothing() throws {
        power.batteryMode = 1
        try closeLidWhileOn()
        XCTAssertEqual(power.modeCalls, [])
        XCTAssertNil(keepAwake.status().lowPowerRestoresTo)
    }

    func testModeChangedByUserMeanwhileIsLeftAlone() throws {
        try closeLidWhileOn()
        power.batteryMode = 0  // changed in System Settings while the lid was closed
        lidClosed = false
        try keepAwake.syncLowPower()
        XCTAssertEqual(power.modeCalls, [1], "no restore over the user's own change")
        XCTAssertEqual(power.batteryMode, 0)
        XCTAssertNil(keepAwake.status().lowPowerRestoresTo)
    }

    func testTurnOffRestoresLowPower() throws {
        try closeLidWhileOn()
        try keepAwake.turnOff(source: .cli)
        XCTAssertEqual(power.modeCalls, [1, 2])
        XCTAssertEqual(power.batteryMode, 2)
        XCTAssertFalse(keepAwake.status().effective)
    }

    func testAutoOffAtLaunchRestoresLowPower() throws {
        try keepAwake.turnOn(source: .cli, hours: 1)
        lidClosed = true
        try keepAwake.syncLowPower()
        clock = hours(2)
        try keepAwake.applyAtLaunch()
        XCTAssertEqual(power.modeCalls, [1, 2])
    }

    func testSystemTerminationRestoresLowPower() throws {
        try closeLidWhileOn()
        try keepAwake.releaseForTermination(userInitiated: false)
        XCTAssertEqual(power.modeCalls, [1, 2])
    }

    func testPauseSkipsLowPowerUntilItExpires() throws {
        keepAwake.settings.lowPowerPausedUntil = hours(24)
        try closeLidWhileOn()
        XCTAssertEqual(power.modeCalls, [], "paused")
        clock = hours(25)
        try keepAwake.syncLowPower()
        XCTAssertEqual(power.modeCalls, [1], "re-armed after the pause")
    }

    func testPermanentPauseNeverSwitches() throws {
        keepAwake.settings.lowPowerPausedUntil = .distantFuture
        try closeLidWhileOn()
        clock = hours(24 * 365)
        try keepAwake.syncLowPower()
        XCTAssertEqual(power.modeCalls, [])
    }

    func testPausingWhileActiveRestoresAtOnce() throws {
        try closeLidWhileOn()
        keepAwake.settings.lowPowerPausedUntil = hours(24)
        XCTAssertEqual(power.modeCalls, [1, 2])
        XCTAssertNil(keepAwake.status().lowPowerRestoresTo)
    }

    func testRelaunchWithLidOpenRestoresRememberedMode() throws {
        try closeLidWhileOn()
        lidClosed = false
        let relaunched = KeepAwake(power: power, defaults: store, isOnAC: { true }, isLidClosed: { false },
                                   isSetupInstalled: { true }, bootSession: { "boot-A" }, now: { [unowned self] in clock })
        try relaunched.syncLowPower()
        XCTAssertEqual(power.modeCalls, [1, 2])
        XCTAssertNil(relaunched.status().lowPowerRestoresTo)
    }

    func testLowPowerFailureRemembersNothing() throws {
        power.modeError = setupRequired
        try keepAwake.turnOn(source: .cli)
        lidClosed = true
        XCTAssertThrowsError(try keepAwake.syncLowPower())
        XCTAssertNil(keepAwake.status().lowPowerRestoresTo)
        XCTAssertTrue(keepAwake.status().effective, "keep-awake itself is unaffected")
    }

    func testLowPowerSettingText() {
        XCTAssertEqual(Settings(mode: .always, autoOffHours: 24, restoreAfterRestart: false).lowPowerText, "on")
        XCTAssertEqual(Settings(mode: .always, autoOffHours: 24, restoreAfterRestart: false,
                                lowPowerPausedUntil: .distantFuture).lowPowerText, "off")
        XCTAssertTrue(Settings(mode: .always, autoOffHours: 24, restoreAfterRestart: false,
                               lowPowerPausedUntil: start).lowPowerText.hasPrefix("off until 2023-11-14T22:13:20"))
    }
}
