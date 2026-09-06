import XCTest
@testable import ShutlidCore

final class StatusTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func at(_ seconds: TimeInterval) -> Date {
        now.addingTimeInterval(seconds)
    }

    private func status(requested: Bool, effective: Bool, mode: Mode = .always, onAC: Bool = true,
                        deadline: Date? = nil, autoOffHours: Int = 24) -> Status {
        Status(requested: requested, effective: effective, mode: mode, onAC: onAC,
               deadline: deadline, autoOffHours: autoOffHours)
    }

    // MARK: - cliText

    func testCliTextOnAlways() {
        let text = status(requested: true, effective: true, deadline: at(23 * 3600 + 12 * 60)).cliText(now: now)
        XCTAssertEqual(text, """
        Requested:  ON
        Effective:  ON
        Mode:       always
        Auto-off:   in 23h 12m
        """)
    }

    func testCliTextOff() {
        let text = status(requested: false, effective: false).cliText(now: now)
        XCTAssertEqual(text, """
        Requested:  OFF
        Effective:  OFF
        Mode:       always
        Auto-off:   24h
        """)
    }

    func testCliTextRequestedOnBatteryOnlyOnPower() {
        let text = status(requested: true, effective: false, mode: .onlyOnPower, onAC: false,
                          deadline: at(3 * 3600)).cliText(now: now)
        XCTAssertEqual(text, """
        Requested:  ON
        Effective:  OFF (on battery; mode: only while connected to power)
        Mode:       only while connected to power
        Auto-off:   in 3h 0m
        """)
    }

    func testCliTextRequestedButNotApplied() {
        let text = status(requested: true, effective: false, onAC: false, deadline: at(3600)).cliText(now: now)
        XCTAssertEqual(text, """
        Requested:  ON
        Effective:  OFF (not applied; run 'shutlid on' again)
        Mode:       always
        Auto-off:   in 1h 0m
        """)
    }

    func testCliTextTurnOffFailed() {
        let text = status(requested: false, effective: true).cliText(now: now)
        XCTAssertEqual(text, """
        Requested:  OFF
        Effective:  ON (turn-off failed; run: sudo pmset disablesleep 0)
        Mode:       always
        Auto-off:   24h
        """)
    }

    func testCliTextAutoOffNever() {
        let text = status(requested: true, effective: true, autoOffHours: 0).cliText(now: now)
        XCTAssertEqual(text, """
        Requested:  ON
        Effective:  ON
        Mode:       always
        Auto-off:   never
        """)
    }

    func testCliTextAutoOffExpired() {
        let text = status(requested: true, effective: true, deadline: at(-1)).cliText(now: now)
        XCTAssertTrue(text.hasSuffix("\nAuto-off:   expired"), text)
        let exactlyNow = status(requested: true, effective: true, deadline: now).cliText(now: now)
        XCTAssertTrue(exactlyNow.hasSuffix("\nAuto-off:   expired"), exactlyNow)
    }

    // MARK: - menuTitle and isOnLike

    func testMenuTitles() {
        XCTAssertEqual(status(requested: true, effective: true, deadline: at(23 * 3600 + 12 * 60)).menuTitle(now: now),
                       "● Keeping awake — auto-off in 23h 12m")
        XCTAssertEqual(status(requested: true, effective: true, autoOffHours: 0).menuTitle(now: now),
                       "● Keeping awake — no auto-off")
        XCTAssertEqual(status(requested: true, effective: true, deadline: at(-5)).menuTitle(now: now),
                       "● Keeping awake — auto-off expired")
        XCTAssertEqual(status(requested: false, effective: true).menuTitle(now: now),
                       "● Keeping awake — no auto-off", "effective wins even when not requested")
        XCTAssertEqual(status(requested: true, effective: false, mode: .onlyOnPower, onAC: false).menuTitle(now: now),
                       "◐ On battery — keeps awake when plugged in")
        XCTAssertEqual(status(requested: true, effective: false, mode: .onlyOnPower, onAC: true).menuTitle(now: now),
                       "○ Normal sleep")
        XCTAssertEqual(status(requested: false, effective: false).menuTitle(now: now), "○ Normal sleep")
    }

    func testIsOnLike() {
        XCTAssertTrue(status(requested: true, effective: true).isOnLike)
        XCTAssertTrue(status(requested: false, effective: true).isOnLike)
        XCTAssertTrue(status(requested: true, effective: false, mode: .onlyOnPower, onAC: false).isOnLike)
        XCTAssertFalse(status(requested: true, effective: false, mode: .onlyOnPower, onAC: true).isOnLike)
        XCTAssertFalse(status(requested: true, effective: false, mode: .always, onAC: false).isOnLike)
        XCTAssertFalse(status(requested: false, effective: false).isOnLike)
    }

    // MARK: - remainingText

    func testRemainingText() {
        XCTAssertEqual(Status.remainingText(until: at(3600), now: now), "1h 0m")
        XCTAssertEqual(Status.remainingText(until: at(59 * 60 + 30), now: now), "59m")
        XCTAssertEqual(Status.remainingText(until: at(30), now: now), "under 1m")
        XCTAssertEqual(Status.remainingText(until: at(24 * 3600 - 0.001), now: now), "23h 59m")
        XCTAssertEqual(Status.remainingText(until: at(3 * 3600 + 10 * 60 + 59), now: now), "3h 10m")
        XCTAssertEqual(Status.remainingText(until: at(60), now: now), "1m")
    }
}
