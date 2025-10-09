import Foundation
import Trace


// MARK: - Synchronous read support
//
// The SerialPort+SyncRead.swift file provides a convenience API for performing
// blocking reads from the underlying file descriptor of a SerialPort instance.
// The core idea is that higher-level API surfaces should not need to reason
// about polling semantics, EINTR handling, or deadline management. Instead this
// extension exposes a handful of helpers that wrap the raw POSIX interfaces in
// a strongly typed, Swift-friendly shape while still offering rich error
// information when things go wrong.


public enum SyncReadError: Error {
  case timeout
  case closed
  case trace(Trace)
}

public enum SyncWriteError: Error {
  case timeout
  case closed
  case trace(Trace)
}

public extension SerialPort {

  /// Reads exactly `count` bytes, waiting for the descriptor to become
  /// readable as needed. If the descriptor closes before `count` bytes have
  /// been read an error is returned.
  ///
  /// - Parameters:
  ///   - count: The number of bytes to read. A `UInt` is accepted but we keep a
  ///            sharp eye on overflow before handing the value to POSIX APIs.
  ///   - timeout: Optional time interval controlling how long the read will
  ///              block while waiting for the first byte of data.
  /// - Returns: A `Result` wrapping the data that was read or a
  ///            `SyncReadError` describing the failure.
  func read(count: UInt, timeout: TimeInterval? = nil) -> Result<Data, SyncReadError> {

    if count == 0 { return .success(Data()) }

    guard let readCount = Int(exactly: count) else {
      // The count parameter is user-controlled and may exceed what can be
      // represented as an Int. Passing a truncated value to `read` would result
      // in undefined behaviour, so we proactively bail out and surface a trace
      // describing the overflow.
      return .failure(.trace(.trace(self, tag: "serial read count overflow", context: count)))
    }

    var buffer   = [UInt8](repeating: 0, count: readCount)
    let deadline = timeout.map { Date().addingTimeInterval($0) }

    while true {
      if let error = waitForReadable(deadline: deadline) { return .failure(error) }

      let bytesRead = buffer.withUnsafeMutableBytes { pointer -> Int in
        guard let baseAddress = pointer.baseAddress else { return 0 }
        return posix_read(descriptor, baseAddress, readCount)
      }

      if bytesRead > 0 {
        // Any positive number of bytes marks a successful read. We return a
        // Data view that only exposes the bytes the system call actually
        // delivered instead of the entire buffer capacity.
        return .success(Data(bytes: buffer, count: bytesRead))
      }

      if bytesRead == 0 {
        // A zero-byte read indicates EOF on a serial port. Treat this as the
        // peer closing the connection rather than an empty read.
        return .failure(.closed)
      }

      if errno == EINTR {
        // The read was interrupted by a signal. Retry the system call to keep
        // the behaviour consistent with normal blocking reads.
        continue
      }

      // Any other errno value is captured in a Trace for visibility. We do not
      // attempt to translate every possible errno, instead leaving diagnosis to
      // the trace consumer.
      return .failure(.trace(.posix(self, tag: "serial read")))
    }
  }


  /// Reads bytes until the serial port goes idle. The method will return as
  /// soon as the descriptor reports no data ready after having previously
  /// delivered at least one byte.
  ///
  /// - Parameter timeout: Optional deadline used to wait for the first byte.
  /// - Returns: A `Result` with all received bytes or an error that explains
  ///            why reading stopped prematurely.
  func read(timeout: TimeInterval? = nil) -> Result<Data, SyncReadError> {

    var collected = [UInt8]()
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    var shouldWaitForDeadline = true
    var buffer = [UInt8](repeating: 0, count: 1024)

    while true {
      if shouldWaitForDeadline {
        if let error = waitForReadable ( deadline: deadline ) { return .failure(error) }
      }
      else {
        // Once at least one byte has been read we switch to polling without a
        // delay. This allows us to coalesce consecutive reads into a single
        // logical payload while still terminating when the device becomes idle.
        switch pollImmediate() {
          case .success ( true      ) : break
          case .success ( false     ) : return .success(Data(collected))
          case .failure ( let error ) : return .failure(error)
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

      if bytesRead == 0 { return .failure(.closed) }

      if errno == EINTR { continue }

      return .failure(.trace(.posix(self, tag: "serial read")))
    }
  }


  /// Reads until a specific delimiter byte is encountered. The read can
  /// optionally include the delimiter in the resulting data and will respect an
  /// optional timeout while waiting for the first byte.
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
          if !includeDelimiter { collected.removeLast() }
          
          // The delimiter marks the logical end of the message. Return the
          // accumulated payload, trimming the sentinel if requested.
          return .success(Data(collected))
        }

        continue
      }

      if bytesRead == 0 { return .failure(.closed) }

      if errno == EINTR { continue }

      return .failure(.trace(.posix(self, tag: "serial read")))
    }
  }


  /// Writes the provided data buffer to the serial port, blocking until the
  /// bytes have been transmitted or an error occurs. The optional timeout is
  /// applied to each wait for the descriptor to become writable.
  ///
  /// - Parameters:
  ///   - data: The payload to send. An empty buffer succeeds immediately.
  ///   - timeout: Optional time interval that bounds how long the method waits
  ///              for the descriptor to become writable.
  /// - Returns: The number of bytes written or a `SyncWriteError` that
  ///            describes the failure.
  func write(_ data: Data, timeout: TimeInterval? = nil) -> Result<Int, SyncWriteError> {

    if data.isEmpty { return .success(0) }

    let deadline = timeout.map { Date().addingTimeInterval($0) }

    return data.withUnsafeBytes { pointer -> Result<Int, SyncWriteError> in
      guard let baseAddress = pointer.baseAddress else { return .success(0) }

      var totalWritten = 0
      let length       = pointer.count

      while totalWritten < length {
        if let error = waitForWritable(deadline: deadline) { return .failure(error) }

        let remaining = length - totalWritten
        let wrote     = posix_write(descriptor, baseAddress.advanced(by: totalWritten), remaining)

        if wrote > 0 {
          totalWritten += wrote
          continue
        }

        if wrote == 0 { return .failure(.closed) }

        if errno == EINTR { continue }

        if errno == EAGAIN || errno == EWOULDBLOCK {
          // Non-blocking descriptors may temporarily refuse additional bytes.
          // Defer to the poll loop to wait for writability again.
          continue
        }

        if errno == EPIPE || errno == EBADF { return .failure(.closed) }

        return .failure(.trace(.posix(self, tag: "serial write")))
      }

      return .success(totalWritten)
    }
  }
}


private extension SerialPort {

  private enum PollOutcome {
    case ready
    case timeout
    case trace(Trace)
  }

  private func waitForEvent(deadline: Date?, events: Int16, tag: String) -> PollOutcome {

    guard let deadline = deadline else { return .ready }

    while true {
      let remaining = deadline.timeIntervalSinceNow

      if remaining <= 0 { return .timeout }

      let milliseconds = min(Int32.max, Int32(max(0, Int(ceil(remaining * 1000)))))

      return pollDescriptor(timeout: milliseconds, events: events, tag: tag)
    }
  }

  /// Waits for the file descriptor to become readable or until the provided
  /// deadline elapses. Returning `nil` indicates the descriptor is ready.
  func waitForReadable(deadline: Date?) -> SyncReadError? {

    switch waitForEvent ( deadline: deadline, events: posix_POLLIN, tag: "serial read" ) {
      case .ready               : return nil
      case .timeout             : return .timeout // // The poll timed out without the descriptor becoming readable
      case .trace ( let trace ) : return .trace(trace)
    }
  }


  /// Polls the descriptor once with a zero timeout and indicates whether data
  /// is ready to be read immediately.
  func pollImmediate() -> Result<Bool, SyncReadError> {

    switch pollDescriptor(timeout: 0, events: posix_POLLIN, tag: "serial read") {
      case .ready   : return .success(true)
      case .timeout : return .success(false)
      case .trace ( let trace ) : return .failure(.trace(trace))
    }
  }


  /// Waits for the file descriptor to become writable or until the provided
  /// deadline elapses. Returning `nil` indicates the descriptor is ready.
  func waitForWritable(deadline: Date?) -> SyncWriteError? {

    switch waitForEvent(deadline: deadline, events: posix_POLLOUT, tag: "serial write") {
      case .ready               : return nil
      case .timeout             : return .timeout
      case .trace ( let trace ) : return .trace(trace)
    }
  }


  /// Thin wrapper around `poll` that performs the standard EINTR retry loop and
  /// packages failures in a consistent trace structure.
  private func pollDescriptor(timeout milliseconds: Int32, events: Int16, tag: String) -> PollOutcome {

    var descriptorState = pollfd(fd: descriptor, events: events, revents: 0)

    while true {
      let ready = withUnsafeMutablePointer(to: &descriptorState) { posix_poll($0, nfds_t(1), milliseconds) }

      if ready > 0  { return .ready }
      if ready == 0 { return .timeout }

      if errno == EINTR { continue }

      return .trace(.posix(self, tag: tag))
    }
  }
}
