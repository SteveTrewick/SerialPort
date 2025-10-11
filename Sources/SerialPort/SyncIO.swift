
import Foundation
import Trace



/*
  SyncIO gives us a reasonably ergonomic synchronous serial API.
 
  This particular piece of code, along with PosixPolling and TimeoutClock
  represent the result of, basically, an almost two day long argument I
  had with Codex in which it keot dropping code that I hated and would refactor.
 
  Eventually, we went through a sort of reverse QA cycle where I was
  rewriting the API and throwing parts up to codex to ensure cases were
  covered. Then I had codex flesh out the rest.
 
  This has been an odd experience, tbqhwyf. The result is a somewhat AI
  acceerated API that now looks like it would have done if I had written
  all of it, which is what I wanted. But really, does it even matter now?
*/


// extend us on to the SerialPort
public extension SerialPort {

  /// A synchronous I/O helper bound to this serial port descriptor.
  var syncIO : SyncIO { SyncIO ( descriptor: descriptor ) }
}


/// Provides synchronous read and write helpers for a serial port file descriptor.
public struct SyncIO {
  

  /// Error cases surfaced by the synchronous API.
  public enum Error: Swift.Error {
     case timeout
     case closed
     case fault(Trace)
     case error(Trace)
  }
  
  
  
  let descriptor : Int32         // wrapped FD
  let poll       : PosixPolling  // poll wrapper, for polling
  

  /// Creates a synchronous I/O helper that wraps the supplied file descriptor.
  ///
  /// - Parameter descriptor: The open file descriptor representing the serial port.
  
  public init ( descriptor : Int32 ) {
    self.descriptor = descriptor
    self.poll       = PosixPolling ( descriptor: descriptor )
  }
  


  /// Reads the specified number of bytes, waiting up to the supplied timeout.
  ///
  /// - Parameters:
  ///   - count: The exact number of bytes to read from the serial port. Must be positive.
  ///   - timeout: The maximum time to wait for the descriptor to become readable.
  /// - Returns: ``Result`` containing the data that was read, or a ``SyncIO.Error`` that describes why reading failed.
 
  public func read ( count: Int, timeout: PosixPolling.Timeout = .indefinite ) -> Result<Data, SyncIO.Error> {

    // bail if we have a dumb parameter, how ya gonna read -12 bytes, dumbass
    guard count > 0 else {
      return .failure (
        .error ( .trace ( self, tag: "read count must be > 0" ) )
      )
    }
    
    var buffer  = [UInt8](repeating: 0, count: count)
    var timeout = timeout
    var clock   = TimeoutClock()  // start the clock!
    
    while true {
      
      // poll. if we get an error, we bail out right away
      if let error = check ( poll.timeout ( timeout, for: .read ) ) { return .failure(error) }
      
      // try to read some bytes
      let bytes_read = buffer.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else {
          errno = EFAULT
          return -1
        }
        return posix_read ( descriptor, base, count )
      }
      
      // did we get some?
      if bytes_read >= 0 {
        return bytes_read > 0 ? .success ( Data ( bytes: buffer, count: bytes_read ) ) // yay!
                              : .failure ( .closed )                                   // bummer!
      }
      
      // are we in error (we are, because bytes_read < 0)
      if errno != 0 {
        
        // if it's EINTR & co, we're going round again, but we need to decrement our
        // timeout as we have used some of it
        if errno == EFAULT {
          return .failure ( .fault ( .trace ( self, tag: "sync read buffer fault" ) ) )
        }

        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }

        // rude!
        if errno == EPIPE || errno == EBADF { return .failure ( .closed ) }

        // bork
        else { return  .failure( .error( .posix(self, tag: "serial read")) ) } // all is lost
      }
      
      
    }
  }
  
  
  

  /// Reads at least one chunk of bytes and continues until the descriptor becomes idle.
  ///
  /// - Parameters:
  ///   - timeout: The maximum time to wait for readability before the first chunk is received.
  ///   - maxbuffer: The maximum number of bytes to read per iteration while draining the descriptor.
  /// - Returns: ``Result`` containing the accumulated data, or a ``SyncIO.Error`` if reading failed.
  
  public func read ( timeout: PosixPolling.Timeout = .indefinite, maxbuffer: Int = 1024 ) -> Result<Data, SyncIO.Error> {
    
    guard maxbuffer > 0 else {
      return .failure (
        .error ( .trace ( self, tag: "maxbuffer must be > 0" ) )
      )
    }

    var collected    = [UInt8]()
    var should_wait  = true
    var buffer       = [UInt8](repeating: 0, count: maxbuffer)
    var timeout      = timeout
    var clock        = TimeoutClock()
    
    
    while true {
      // we should wait if : 1) this is the first go around.
      //                     2) we encounter EINTR during read before we have read any bytes
      if should_wait {
        // poll, check error and bail if we get one
        if let error = check ( poll.timeout(timeout, for: .read) ) { return .failure(error) }
      }
      // otherwise we should poll the descriptor with no timeout
      else {
        switch poll.immediate ( for: .read ) {
          case .ready               : break                               // descriptor is ready, try and read some bytes, see below
          case .idle                : return .success ( Data(collected) ) // descriptor is idle, we have finished
          case .closed              : return .failure ( .closed        ) // descriptor is closed
          case .error ( let trace ) : return .failure ( .error(trace)   ) // we have failed
        }
      }
      
      // attempt a read
      let capacity = buffer.count // we need to pull this out because we can't refer to buffer inside the unsafe
      let bytes_read = buffer.withUnsafeMutableBytes { buffer in
        guard let base = buffer.baseAddress else {
          errno = EFAULT
          return -1
        }
        return posix_read(descriptor, base, capacity)
      }
      
      // error.
      if bytes_read < 0 {

        // if its one of these, we burn some time and go again, repolling if we
        // haven't started collecting chars yet.
        if errno == EFAULT {
          return .failure ( .fault ( .trace ( self, tag: "streaming read buffer fault" ) ) )
        }

        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
          timeout     = timeout.decrement(elapsed: clock.elapsed() )
          should_wait = collected.isEmpty
          errno = 0
          continue
        }

        // rude!
        if errno == EPIPE || errno == EBADF { return .failure ( .closed ) }

        // bork
        else { return .failure(.error(.posix(self, tag: "serial read"))) }
      }
      
      if bytes_read == 0 { return .failure(.closed) }            // rude!
      else {
        collected.append(contentsOf: buffer[0..<bytes_read])     // collect some bytes
        should_wait = false
        continue
      }
      
    }
    
  }



  /// Reads bytes until the delimiter is encountered, optionally including it in the result.
  ///
  /// - Parameters:
  ///   - delimiter: The byte value that terminates the read.
  ///   - includeDelimiter: Whether to include the delimiter byte in the returned data.
  ///   - timeout: The maximum time to wait for readability while scanning for the delimiter.
  /// - Returns: ``Result`` containing the collected data, or a ``SyncIO.Error`` if reading failed.
  
  public func read ( until delimiter: UInt8, includeDelimiter: Bool, timeout: PosixPolling.Timeout = .indefinite ) -> Result<Data, SyncIO.Error> {

    var collected = [UInt8]()
    var timeout   = timeout
    var clock     = TimeoutClock()

    while true {
      // poll, check error and bail if we get one
      if let error = check ( poll.timeout(timeout, for: .read) ) { return .failure(error) }
      
      // decrement the timeout so we don't just keep reapplying it to the poll.
      timeout = timeout.decrement ( elapsed: clock.elapsed() )
      
      // try and read some bytes
      var byte : UInt8 = 0
      let bytes_read = withUnsafeMutablePointer(to: &byte) {
        posix_read ( descriptor, $0, 1 )
      }

      // if we got some, happy path
      if bytes_read > 0 {
        collected.append ( byte )
        
        // are these the driods we're looking for?
        if byte == delimiter {
          if !includeDelimiter { collected.removeLast() }
          return .success ( Data ( collected ) )
        }

        continue
      }

      if bytes_read == 0 { return .failure ( .closed ) }  // rude!

      // we are in error
      if errno != 0 {
        
        // but it's EINTR or its chums so #yolo, let's go again but burn some timeout
        if errno == EFAULT {
          return .failure ( .fault ( .trace ( self, tag: "sync read byte buffer fault" ) ) )
        }

        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }
        
        // rude!
        if errno == EPIPE || errno == EBADF { return .failure ( .closed ) }

        // bork
        else { return .failure ( .error ( .posix ( self, tag: "serial read" ) ) ) }
      }
    }
  }



  /// Writes the supplied data, blocking until all bytes are written or a timeout occurs.
  ///
  /// - Parameters:
  ///   - data: The bytes to write to the serial port. Must not be empty.
  ///   - timeout: The maximum time to wait for the descriptor to become writable.
  /// - Returns: ``Result`` containing the number of bytes written, or a ``SyncIO.Error`` describing the failure.
  
  public func write ( _ data: Data, timeout: PosixPolling.Timeout = .indefinite ) -> Result<Int, SyncIO.Error> {

    // if you have passed zero write bytes you have certainly broken something
    // which you should fix. no silent noop for you.
    guard data.count > 0 else {
      return .failure (
        .error ( .trace (self, tag: "data.count muxt be > 0" ) )
      )
    }
    
    var total_written = 0
    var timeout       = timeout
    var clock         = TimeoutClock()
    let length        = data.count // we can't refer back to data in the unsafe closure

    while total_written < length {

      // poll, check for error and bail if we get one
      if let error = check ( poll.timeout ( timeout, for: .write ) ) { return .failure ( error ) }

      // burn the timer becuase the timeout covers the whole write
      timeout = timeout.decrement ( elapsed: clock.elapsed() )

      // try and write some bytes.
      let wrote : Int = data.withUnsafeBytes { buffer in
        // TODO: are we sure, I don't /think/ this is necessary, but if it is, it is necessary elsewhere as well.
        guard let base = buffer.baseAddress else {
          errno = EFAULT
          return -1
        }
        return posix_write ( descriptor, base.advanced ( by: total_written ), length - total_written )
      }

      // we wrote some, but did we do enough?
      if wrote > 0 {
        total_written += wrote
        continue
      }

      if wrote == 0 { return .failure ( .closed ) }  // rude!

      // we are in error, but which one?
      if errno != 0 {
        
        // if its one of these lads, we go around again
        if errno == EFAULT {
          return .failure ( .fault ( .trace ( self, tag: "sync write buffer fault" ) ) )
        }

        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }

        // rude!
        if errno == EPIPE || errno == EBADF { return .failure ( .closed ) }

        // oh dear
        return .failure ( .error ( .posix ( self, tag: "serial write" ) ) )
      }

    }

    return .success ( total_written )
  }

  /// Converts a poll outcome to a `SyncIO.Error`, or returns `nil` when the descriptor is ready.
  ///
  /// - Parameter outcome: The result of polling the descriptor for readiness.
  /// - Returns: ``SyncIO.Error`` when the descriptor is not ready, or `nil` when it is.
  
  func check ( _ outcome: PosixPolling.PollOutcome ) -> SyncIO.Error? {
    switch outcome {
      case .ready               : return nil
      case .timeout             : return .timeout
      case .closed              : return .closed
      case .error ( let trace ) : return .error ( trace )
    }
  }
}






