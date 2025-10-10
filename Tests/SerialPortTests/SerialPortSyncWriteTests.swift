import Foundation
import XCTest
@testable import SerialPort

#if os(Linux)
import Glibc
#else
import Darwin
#endif

final class SerialPortSyncWriteTests: XCTestCase {

    override class func setUp() {
        super.setUp()
        #if os(Linux)
        _ = Glibc.signal(SIGPIPE, SIG_IGN)
        #else
        _ = Darwin.signal(SIGPIPE, SIG_IGN)
        #endif
    }

    func testWriteSendsAllBytes() throws {
        let context = try SocketPairContext()
        defer { context.closeDescriptors() }

        let payload = Data("hello".utf8)
        let result = context.serial.syncIO.write(payload, timeout: .seconds(1))

        switch result {
        case .success(let count):
            XCTAssertEqual(count, payload.count)
        case .failure(let error):
            XCTFail("Expected success, got \(error)")
        }

        let received = context.peer.readData(ofLength: payload.count)
        XCTAssertEqual(received, payload)
    }

    func testWriteTimesOutWhenDescriptorNotWritable() throws {
        let context = try SocketPairContext()
        defer { context.closeDescriptors() }

        try context.setNonBlocking()
        try context.fillSendBuffer()

        let payload = Data("x".utf8)
        let result = context.serial.syncIO.write(payload, timeout: .seconds(0.01))

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

    func testWriteReportsClosedDescriptor() throws {
        let context = try SocketPairContext()
        defer { context.closeDescriptors() }

        context.peer.closeFile()

        let payload = Data("z".utf8)
        let result = context.serial.syncIO.write(payload, timeout: .seconds(1))

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

    final class SocketPairContext {
        let serial: SerialPort
        let peer: FileHandle

        private let localDescriptor: Int32
        init() throws {
            var descriptors = [Int32](repeating: 0, count: 2)
            #if os(Linux)
            let socketType = Int32(SOCK_STREAM.rawValue)
            #else
            let socketType = SOCK_STREAM
            #endif

            guard socketpair(AF_UNIX, socketType, 0, &descriptors) == 0 else {
                throw ContextError.socketCreationFailed(errno)
            }

            self.localDescriptor = descriptors[0]
            self.serial = SerialPort(descriptor: descriptors[0])
            self.peer = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
        }

        func setNonBlocking() throws {
            let flags = fcntl(localDescriptor, F_GETFL, 0)
            guard flags >= 0 else {
                throw ContextError.nonBlockingConfigurationFailed(errno)
            }

            guard fcntl(localDescriptor, F_SETFL, flags | O_NONBLOCK) >= 0 else {
                throw ContextError.nonBlockingConfigurationFailed(errno)
            }
        }

        func fillSendBuffer() throws {
            let chunk = [UInt8](repeating: 0x2A, count: 4096)

            while true {
                let wrote = chunk.withUnsafeBytes { pointer -> Int in
                    guard let baseAddress = pointer.baseAddress else { return 0 }
                    #if os(Linux)
                    return Glibc.write(localDescriptor, baseAddress, pointer.count)
                    #else
                    return Darwin.write(localDescriptor, baseAddress, pointer.count)
                    #endif
                }

                if wrote > 0 {
                    continue
                }

                if wrote == 0 {
                    break
                }

                if errno == EINTR {
                    continue
                }

                if errno == EAGAIN || errno == EWOULDBLOCK {
                    break
                }

                throw ContextError.bufferFillFailed(errno)
            }
        }

        func closeDescriptors() {
            peer.closeFile()
            _ = close(localDescriptor)
        }

        enum ContextError: Error {
            case socketCreationFailed(Int32)
            case nonBlockingConfigurationFailed(Int32)
            case bufferFillFailed(Int32)
        }
    }
}
