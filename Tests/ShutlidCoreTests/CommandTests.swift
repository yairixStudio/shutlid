import XCTest
@testable import ShutlidCore

final class CommandTests: XCTestCase {
    private func assertFails(_ arguments: [String], file: StaticString = #filePath, line: UInt = #line) {
        if case .success(let command) = Command.parse(arguments) {
            XCTFail("\(arguments) parsed as \(command)", file: file, line: line)
        }
    }

    func testEveryCommand() {
        XCTAssertEqual(Command.parse(["on"]), .success(.on(hours: nil)))
        XCTAssertEqual(Command.parse(["on", "--for", "4"]), .success(.on(hours: 4)))
        XCTAssertEqual(Command.parse(["off"]), .success(.off))
        XCTAssertEqual(Command.parse(["status"]), .success(.status))
        XCTAssertEqual(Command.parse(["setup"]), .success(.setup))
        XCTAssertEqual(Command.parse(["log"]), .success(.log))
        XCTAssertEqual(Command.parse(["--version"]), .success(.version))
        XCTAssertEqual(Command.parse(["version"]), .success(.version))
        XCTAssertEqual(Command.parse(["--help"]), .success(.help))
        XCTAssertEqual(Command.parse(["help"]), .success(.help))
        XCTAssertEqual(Command.parse(["-h"]), .success(.help))
    }

    func testForBounds() {
        XCTAssertEqual(Command.parse(["on", "--for", "1"]), .success(.on(hours: 1)))
        XCTAssertEqual(Command.parse(["on", "--for", "720"]), .success(.on(hours: 720)))
        assertFails(["on", "--for", "0"])
        assertFails(["on", "--for", "721"])
        assertFails(["on", "--for", "-4"])
        assertFails(["on", "--for", "abc"])
        assertFails(["on", "--for", "1.5"])
        assertFails(["on", "--for"])
        assertFails(["on", "4"])
        assertFails(["on", "--for", "4", "extra"])
    }

    func testUnknownAndMalformed() {
        assertFails([])
        assertFails(["frobnicate"])
        assertFails(["ON"])
        assertFails(["off", "now"])
        assertFails(["status", "--for", "4"])
        XCTAssertEqual(Command.parse(["frobnicate"]), .failure(UsageError("unknown command 'frobnicate'")))
    }
}
