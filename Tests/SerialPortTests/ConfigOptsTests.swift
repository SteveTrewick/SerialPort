import XCTest
@testable import SerialPort

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class ConfigOptsTests: XCTestCase {
    func testCommonBaudRatesAreAccessible() {
        XCTAssertEqual(BaudRate.baud_9600.speed, speed_t(B9600))
        XCTAssertEqual(BaudRate.baud_115200.speed, speed_t(B115200))
    }

    func testPlatformSpecificBaudRatesCompile() {
#if !os(Linux)
        XCTAssertEqual(BaudRate.baud_7200.speed, speed_t(B7200))
        XCTAssertEqual(BaudRate.baud_14400.speed, speed_t(B14400))
        XCTAssertEqual(BaudRate.baud_28800.speed, speed_t(B28800))
        XCTAssertEqual(BaudRate.baud_76800.speed, speed_t(B76800))
#endif
    }
}
