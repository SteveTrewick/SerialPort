import XCTest
@testable import SerialPort

final class SerialPortTests: XCTestCase {
    func testExample() throws {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
        XCTAssertEqual(SerialPort().text, "Hello, World!")
    }
}
