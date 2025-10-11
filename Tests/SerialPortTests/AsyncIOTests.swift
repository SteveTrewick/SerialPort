import XCTest
import Foundation
import Dispatch
@testable import SerialPort

#if os(Linux)
import Glibc
#else
import Darwin
#endif

private var retainedIO = [AsyncIO]()

private func retainIO(_ io: AsyncIO) {
    retainedIO.append(io)
}

final class AsyncIOTests: XCTestCase {

    func testReadCountWaitsForExactBytes() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let reader = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(reader)

        defer {
            context.stopForwarding()
            reader.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()

        let expectation = expectation(description: "read exact number of bytes")

        reader.read(count: 6) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "abcdef")
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }

        context.asyncWrite("abc")
        context.asyncWrite("def", after: .milliseconds(50))

        wait(for: [expectation], timeout: 2.0)
    }

    func testReadAvailableReturnsBufferedData() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let reader = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(reader)

        defer {
            context.stopForwarding()
            reader.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()

        context.asyncWrite("buffered")
        usleep(50_000)

        let expectation = expectation(description: "readAvailable returns buffered data")

        reader.read { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "buffered")
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testReadAvailableReturnsEmptyDataWhenBufferEmpty() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let reader = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(reader)

        defer {
            context.stopForwarding()
            reader.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()

        let expectation = expectation(description: "readAvailable returns empty data")

        reader.read { result in
            switch result {
            case .success(let data):
                XCTAssertTrue(data.isEmpty)
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testReadUntilDelimiterReturnsAvailableData() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let reader = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(reader)

        defer {
            context.stopForwarding()
            reader.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()

        let lineExpectation = expectation(description: "read line without delimiter")
        let remainderExpectation = expectation(description: "buffer retains trailing data")

        let newline: UInt8 = 0x0A

        reader.read(until: newline, includeDelimiter: false) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
                lineExpectation.fulfill()

                self.readRemainingBytes(5, using: reader, expectation: remainderExpectation) { data in
                    XCTAssertEqual(String(data: data, encoding: .utf8), "world")
                }

            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
                lineExpectation.fulfill()
                remainderExpectation.fulfill()
            }
        }

        context.asyncWrite("hello\nworld")

        wait(for: [lineExpectation, remainderExpectation], timeout: 2.0)
    }

    func testReadAvailableCooperatesWithPendingRequests() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let reader = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(reader)

        defer {
            context.stopForwarding()
            reader.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()

        let countExpectation = expectation(description: "pending count request completes")
        let drainExpectation = expectation(description: "readAvailable completes after pending request")

        var countCompleted = false

        reader.read(count: 5) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "alpha")
                countCompleted = true
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
            countExpectation.fulfill()
        }

        reader.read { result in
            switch result {
            case .success(let data):
                XCTAssertTrue(data.isEmpty)
                XCTAssertTrue(countCompleted)
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
            drainExpectation.fulfill()
        }

        context.asyncWrite("alpha")

        wait(for: [countExpectation, drainExpectation], timeout: 2.0)

        let delimiterExpectation = expectation(description: "delimiter read succeeds after drain")
        let followupCountExpectation = expectation(description: "count read succeeds after drain")

        let newline: UInt8 = 0x0A

        reader.read(until: newline, includeDelimiter: false) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "beta")
                delimiterExpectation.fulfill()

                self.readRemainingBytes(3, using: reader, expectation: followupCountExpectation) { data in
                    XCTAssertEqual(String(data: data, encoding: .utf8), "xyz")
                }

            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
                delimiterExpectation.fulfill()
                followupCountExpectation.fulfill()
            }
        }

        context.asyncWrite("beta\nxyz")

        wait(for: [delimiterExpectation, followupCountExpectation], timeout: 2.0)
    }

    func testReadUntilDelimiterTimesOutWithoutDelimiter() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let reader = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(reader)

        defer {
            context.stopForwarding()
            reader.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()

        let timeoutExpectation = expectation(description: "delimiter timeout")
        let remainderExpectation = expectation(description: "buffer retains data after timeout")

        let newline: UInt8 = 0x0A

        reader.read(until: newline, includeDelimiter: false, timeout: .wait(100)) { result in
            switch result {
            case .failure(.timeout):
                timeoutExpectation.fulfill()

                self.readRemainingBytes(3, using: reader, expectation: remainderExpectation) { data in
                    XCTAssertEqual(String(data: data, encoding: .utf8), "abc")
                }

            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
                timeoutExpectation.fulfill()
                remainderExpectation.fulfill()
            case .success:
                XCTFail("Unexpected success")
                timeoutExpectation.fulfill()
                remainderExpectation.fulfill()
            }
        }

        context.asyncWrite("abc")

        wait(for: [timeoutExpectation, remainderExpectation], timeout: 2.0)
    }

    func testReadUntilDelimiterSpanningMultipleWritesIncludesDelimiter() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let reader = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(reader)

        defer {
            context.stopForwarding()
            reader.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()

        let lineExpectation = expectation(description: "read line including delimiter")
        let remainderExpectation = expectation(description: "buffer retains trailing data after delimiter")

        let newline: UInt8 = 0x0A

        reader.read(until: newline, includeDelimiter: true) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "foo\n")
                lineExpectation.fulfill()

                self.readRemainingBytes(3, using: reader, expectation: remainderExpectation) { data in
                    XCTAssertEqual(String(data: data, encoding: .utf8), "bar")
                }

            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
                lineExpectation.fulfill()
                remainderExpectation.fulfill()
            }
        }

        context.asyncWrite("foo")
        context.asyncWrite("\nbar", after: .milliseconds(50))

        wait(for: [lineExpectation, remainderExpectation], timeout: 2.0)
    }

    func testAsyncIOForwardsToExistingHandler() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")

        let handlerExpectation = expectation(description: "existing handler receives data")
        let readerExpectation = expectation(description: "async io receives data")

        var forwarded = Data()
        context.serial.stream.handler = { result in
            switch result {
            case .success(let data):
                forwarded.append(data)
                if forwarded.count >= 6 {
                    handlerExpectation.fulfill()
                }
            case .failure(let error):
                XCTFail("Existing handler error: \(error)")
                handlerExpectation.fulfill()
            }
        }

        let reader = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(reader)

        defer {
            context.stopForwarding()
            reader.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()

        reader.read(count: 6) { result in
            switch result {
            case .success(let data):
                XCTAssertEqual(String(data: data, encoding: .utf8), "abcdef")
                readerExpectation.fulfill()
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
                readerExpectation.fulfill()
            }
        }

        context.asyncWrite("abc")
        context.asyncWrite("def", after: .milliseconds(50))

        wait(for: [handlerExpectation, readerExpectation], timeout: 2.0)
    }

    func testWriteSendsDataToPeer() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let io = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(io)

        defer {
            context.stopForwarding()
            io.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()

        let completionExpectation = expectation(description: "write completes")
        let peerExpectation = expectation(description: "peer receives data")

        DispatchQueue.global().async {
            let data = context.readFromSerial(byteCount: 6)
            XCTAssertEqual(String(data: data, encoding: .utf8), "abcdef")
            peerExpectation.fulfill()
        }

        io.write(Data("abcdef".utf8)) { result in
            switch result {
            case .success(let count):
                XCTAssertEqual(count, 6)
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
            completionExpectation.fulfill()
        }

        wait(for: [completionExpectation, peerExpectation], timeout: 2.0)
    }

    func testWriteReportsStreamError() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let io = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(io)

        defer {
            context.stopForwarding()
            io.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()
        context.serial.close()

        let expectation = expectation(description: "write fails with stream error")

        io.write(Data("oops".utf8)) { result in
            switch result {
            case .success:
                XCTFail("Expected failure")
            case .failure(let error):
                if case .stream = error {
                    // expected
                } else {
                    XCTFail("Expected stream error, got \(error)")
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    func testWriteReportsClosedAfterInvalidate() throws {
        let context = try PipeContext()
        let callbackQueue = DispatchQueue(label: "AsyncIOTests.callback")
        let io = context.serial.asyncIO(callbackQueue: callbackQueue)
        retainIO(io)

        defer {
            context.stopForwarding()
            io.invalidate()
            callbackQueue.sync { }
            usleep(50_000)
            context.closeDescriptors()
        }

        context.startForwarding()
        io.invalidate()

        let expectation = expectation(description: "write fails with closed error")

        io.write(Data("noop".utf8)) { result in
            switch result {
            case .success:
                XCTFail("Expected failure")
            case .failure(let error):
                if case .closed = error {
                    // expected
                } else {
                    XCTFail("Expected closed, got \(error)")
                }
            }
            expectation.fulfill()
        }

        wait(for: [expectation], timeout: 2.0)
    }

    private func readRemainingBytes(_ count: Int,
                                    using reader: AsyncIO,
                                    expectation: XCTestExpectation,
                                    validation: @escaping (Data) -> Void) {
        reader.read(count: count) { result in
            switch result {
            case .success(let data):
                validation(data)
            case .failure(let error):
                XCTFail("Unexpected error: \(error)")
            }
            expectation.fulfill()
        }
    }

    final class PipeContext {
        let serial: SerialPort
        let writer: FileHandle

        private let readDescriptor: Int32
        private let writeDescriptor: Int32
        private let forwardQueue = DispatchQueue(label: "AsyncIOTests.forwarder")
        private var readSource: DispatchSourceRead?

        init() throws {
            var descriptors = [Int32](repeating: 0, count: 2)
            #if os(Linux)
            let socketType = Int32(SOCK_STREAM.rawValue)
            #else
            let socketType = SOCK_STREAM
            #endif

            guard socketpair(AF_UNIX, socketType, 0, &descriptors) == 0 else {
                let error = errno
                throw PipeError.creationFailed(error)
            }

            self.serial = SerialPort(descriptor: descriptors[0])
            self.writer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
            self.readDescriptor = descriptors[0]
            self.writeDescriptor = descriptors[1]
        }

        func startForwarding() {
            guard readSource == nil else { return }

            let source = DispatchSource.makeReadSource(fileDescriptor: readDescriptor, queue: forwardQueue)

            source.setEventHandler { [weak self] in
                guard let self = self else { return }

                var buffer = [UInt8](repeating: 0, count: 1024)
                let capacity = buffer.count

                while true {
                    let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                        guard let baseAddress = pointer.baseAddress else { return 0 }
                        return read(self.readDescriptor, baseAddress, capacity)
                    }

                    if bytesRead > 0 {
                        let data = Data(bytes: buffer, count: bytesRead)
                        self.serial.stream.handler?(.success(data))

                        if bytesRead < capacity {
                            break
                        }

                        continue
                    }

                    if bytesRead == -1 && errno == EINTR {
                        continue
                    }

                    break
                }
            }

            source.resume()
            readSource = source
        }

        func stopForwarding() {
            guard let source = readSource else { return }

            readSource = nil

            let semaphore = DispatchSemaphore(value: 0)

            source.setCancelHandler {
                semaphore.signal()
            }

            source.cancel()

            semaphore.wait()
        }

        func asyncWrite(_ string: String, after delay: DispatchTimeInterval = .milliseconds(0)) {
            asyncWrite(Data(string.utf8), after: delay)
        }

        func asyncWrite(_ data: Data, after delay: DispatchTimeInterval = .milliseconds(0)) {
            DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                self.writer.write(data)
            }
        }

        func readFromSerial(byteCount: Int) -> Data {
            var collected = Data()

            while collected.count < byteCount {
                let remaining = byteCount - collected.count
                var buffer = [UInt8](repeating: 0, count: remaining)

                let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
                    guard let baseAddress = pointer.baseAddress else { return 0 }
                    return read(self.writeDescriptor, baseAddress, remaining)
                }

                if bytesRead <= 0 {
                    break
                }

                collected.append(contentsOf: buffer.prefix(bytesRead))
            }

            return collected
        }

        func closeDescriptors() {
            writer.closeFile()
            _ = close(readDescriptor)
        }

        enum PipeError: Error {
            case creationFailed(Int32)
        }
    }
}
