import Foundation
import XCTest
@testable import SerialPort

final class SerialPortSyncReadTests: XCTestCase {

    func testReadReturnsData() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        context.asyncWrite("hello")

        let result = context.serial.read(count: 5, timeout: 1)

        switch result {
        case .success(let data):
            XCTAssertEqual(data, Data("hello".utf8))
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testReadTimesOutWhenNoDataArrives() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        let result = context.serial.read(count: 1, timeout: 0.1)

        switch result {
        case .success:
            XCTFail("Expected timeout failure")
        case .failure(let error):
            if case .timeout = error {
                // expected
            } else {
                XCTFail("Expected timeout, got \(error)")
            }
        }
    }

    func testReadReportsClosedDescriptor() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        context.writer.closeFile()

        let result = context.serial.read(count: 1, timeout: 1)

        switch result {
        case .success:
            XCTFail("Expected closed failure")
        case .failure(let error):
            if case .closed = error {
                // expected
            } else {
                XCTFail("Expected closed, got \(error)")
            }
        }
    }
}
