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
      if let deadline = deadline {
        while true {
          let remaining = deadline.timeIntervalSinceNow

          if remaining <= 0 {
            return .failure(.timeout)
          }

          let milliseconds = min(Int32.max, Int32(max(0, Int(ceil(remaining * 1000)))))
          var descriptorState = pollfd(fd: descriptor, events: posix_POLLIN, revents: 0)
          let ready = withUnsafeMutablePointer(to: &descriptorState) {
            posix_poll($0, nfds_t(1), milliseconds)
          }

          if ready > 0 {
            break
          }

          if ready == 0 {
            return .failure(.timeout)
          }

          if errno == EINTR {
            continue
          }

          return .failure(.trace(.posix(self, tag: "serial read")))
        }
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
}
