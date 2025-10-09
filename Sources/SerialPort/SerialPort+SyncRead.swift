import Foundation
import Trace


public enum SyncReadError: Error {
  case timeout
  case closed
  case trace(Trace)
}

public extension SerialPort {

  func read(count: UInt, timeout: TimeInterval? = nil) -> Result<Data, SyncReadError> {

    if count == 0 {
      return .success(Data())
    }

    guard let readCount = Int(exactly: count) else {
      return .failure(.trace(.trace(self, tag: "serial read count overflow", context: count)))
    }

    var buffer = [UInt8](repeating: 0, count: readCount)
    let deadline = timeout.map { Date().addingTimeInterval($0) }

    while true {
      if let error = waitForReadable(deadline: deadline) {
        return .failure(error)
      }

      let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
        guard let baseAddress = pointer.baseAddress else { return 0 }
        return posix_read(descriptor, baseAddress, readCount)
      }

      if bytesRead > 0 {
        return .success(Data(bytes: buffer, count: bytesRead))
      }

      if bytesRead == 0 {
        return .failure(.closed)
      }

      if errno == EINTR {
        continue
      }

      return .failure(.trace(.posix(self, tag: "serial read")))
    }
  }


  func read(timeout: TimeInterval? = nil) -> Result<Data, SyncReadError> {

    var collected = [UInt8]()
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    var shouldWaitForDeadline = true
    var buffer = [UInt8](repeating: 0, count: 1024)

    while true {
      if shouldWaitForDeadline {
        if let error = waitForReadable(deadline: deadline) {
          return .failure(error)
        }
      } else {
        switch pollImmediate() {
        case .success(true):
          break
        case .success(false):
          return .success(Data(collected))
        case .failure(let error):
          return .failure(error)
        }
      }

      let capacity = buffer.count
      let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
        guard let baseAddress = pointer.baseAddress else { return 0 }
        return posix_read(descriptor, baseAddress, capacity)
      }

      if bytesRead > 0 {
        collected.append(contentsOf: buffer[0..<bytesRead])
        shouldWaitForDeadline = false
        continue
      }

      if bytesRead == 0 {
        return .failure(.closed)
      }

      if errno == EINTR {
        continue
      }

      return .failure(.trace(.posix(self, tag: "serial read")))
    }
  }


  func read(until delimiter: UInt8, includeDelimiter: Bool, timeout: TimeInterval? = nil) -> Result<Data, SyncReadError> {

    var collected = [UInt8]()
    let deadline = timeout.map { Date().addingTimeInterval($0) }

    while true {
      if let error = waitForReadable(deadline: deadline) {
        return .failure(error)
      }

      var byte: UInt8 = 0
      let bytesRead = withUnsafeMutablePointer(to: &byte) { pointer -> Int in
        return posix_read(descriptor, pointer, 1)
      }

      if bytesRead > 0 {
        collected.append(byte)

        if byte == delimiter {
          if !includeDelimiter {
            collected.removeLast()
          }
          return .success(Data(collected))
        }

        continue
      }

      if bytesRead == 0 {
        return .failure(.closed)
      }

      if errno == EINTR {
        continue
      }

      return .failure(.trace(.posix(self, tag: "serial read")))
    }
  }
}


private extension SerialPort {

  func waitForReadable(deadline: Date?) -> SyncReadError? {

    guard let deadline = deadline else {
      return nil
    }

    while true {
      let remaining = deadline.timeIntervalSinceNow

      if remaining <= 0 {
        return .timeout
      }

      let milliseconds = min(Int32.max, Int32(max(0, Int(ceil(remaining * 1000)))))

      switch pollDescriptor(timeout: milliseconds) {
      case .success(let ready) where ready > 0:
        return nil
      case .success:
        return .timeout
      case .failure(let error):
        return error
      }
    }
  }


  func pollImmediate() -> Result<Bool, SyncReadError> {

    switch pollDescriptor(timeout: 0) {
    case .success(let ready):
      return .success(ready > 0)
    case .failure(let error):
      return .failure(error)
    }
  }


  func pollDescriptor(timeout milliseconds: Int32) -> Result<Int32, SyncReadError> {

    var descriptorState = pollfd(fd: descriptor, events: posix_POLLIN, revents: 0)

    while true {
      let ready = withUnsafeMutablePointer(to: &descriptorState) {
        posix_poll($0, nfds_t(1), milliseconds)
      }

      if ready >= 0 {
        return .success(ready)
      }

      if errno == EINTR {
        continue
      }

      return .failure(.trace(.posix(self, tag: "serial read")))
    }
  }
}
