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

    func testReadDrainReturnsAvailableBytes() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        context.asyncWrite("drain")

        let result = context.serial.read(timeout: 1)

        switch result {
        case .success(let data):
            XCTAssertEqual(String(data: data, encoding: .utf8), "drain")
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testReadDrainWithZeroTimeoutAndNoDataTimesOut() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        let result = context.serial.read(timeout: 0)

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

    func testReadUntilDelimiterExcludesDelimiter() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        context.asyncWrite("hello\nworld")

        let newline: UInt8 = 0x0A
        let result = context.serial.read(until: newline, includeDelimiter: false, timeout: 1)

        switch result {
        case .success(let data):
            XCTAssertEqual(String(data: data, encoding: .utf8), "hello")

            let remainder = context.serial.read(timeout: 0.1)

            switch remainder {
            case .success(let tail):
                XCTAssertEqual(String(data: tail, encoding: .utf8), "world")
            case .failure(let error):
                XCTFail("Expected trailing data, got \(error)")
            }
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testReadUntilDelimiterIncludesDelimiter() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        context.asyncWrite("foo\n")

        let newline: UInt8 = 0x0A
        let result = context.serial.read(until: newline, includeDelimiter: true, timeout: 1)

        switch result {
        case .success(let data):
            XCTAssertEqual(String(data: data, encoding: .utf8), "foo\n")
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }
    }

    func testReadUntilDelimiterTimesOut() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        context.asyncWrite("abc")

        let newline: UInt8 = 0x0A
        let result = context.serial.read(until: newline, includeDelimiter: false, timeout: 0.1)

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

    func testReadDrainReportsClosedDescriptor() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        context.writer.closeFile()

        let result = context.serial.read(timeout: 1)

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

    func testReadUntilDelimiterReportsClosedDescriptor() throws {
        let context = try SerialBufferedReaderTests.PipeContext()
        defer { context.closeDescriptors() }

        context.writer.closeFile()

        let newline: UInt8 = 0x0A
        let result = context.serial.read(until: newline, includeDelimiter: false, timeout: 0.1)

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
