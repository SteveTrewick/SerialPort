
import Foundation
import Trace


// extend us on to the SerialPort
public extension SerialPort {

  var syncIO : SyncIO { SyncIO ( descriptor: descriptor ) }
}


public struct SyncIO {
  
  
  // error surfaced by the public API
  public enum Error: Swift.Error {
     case timeout
     case closed
     case error(Trace)
  }
  
  
  
  let descriptor : Int32         // wrapped FD
  let poll       : PosixPolling  // poll wrapper, for polling
  
  
  public init ( descriptor : Int32 ) {
    self.descriptor = descriptor
    self.poll       = PosixPolling ( descriptor: descriptor )
  }
  

  
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
        posix_read ( descriptor, buffer.baseAddress, count )
      }
      
      // did we get some?
      if bytes_read >= 0 {
        return bytes_read > 0 ? .success ( Data ( bytes: buffer, count: bytes_read ) ) // yay!
                              : .failure ( .closed )                                   // bummer!
      }
      
      // are we in error (we are, because bytes_read < 0)
      if errno != 0 {
        // if it's EINTR, we're going round again, but we need to decrement our
        // timeout as we have used some of it
        if errno == EINTR {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }

        if errno == EAGAIN || errno == EWOULDBLOCK {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }

        if errno == EPIPE || errno == EBADF { return .failure ( .closed ) }

        else { return  .failure( .error( .posix(self, tag: "serial read")) ) } // all is lost
      }
      
      
    }
  }
  
  
  
  
  public func read ( timeout: PosixPolling.Timeout = .indefinite, maxbuffer: Int = 1024 ) -> Result<Data, SyncIO.Error> {
    
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
        posix_read(descriptor, buffer.baseAddress, capacity)
      }
      
      // error. if it's EINTR just loop but decrement the timeout
      if bytes_read < 0 {
        if errno == EINTR {
          timeout     = timeout.decrement(elapsed: clock.elapsed() )
          should_wait = collected.isEmpty
          errno = 0
          continue
        }

        if errno == EAGAIN || errno == EWOULDBLOCK {
          timeout     = timeout.decrement(elapsed: clock.elapsed() )
          should_wait = collected.isEmpty
          errno = 0
          continue
        }

        if errno == EPIPE || errno == EBADF { return .failure ( .closed ) }

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
        // but it's EINTR so #yolo, let's go again but burn some timeout
        // Not sure we actually need to do this as we decrement every time through the poll
        if errno == EINTR {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }

        if errno == EAGAIN || errno == EWOULDBLOCK {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }

        if errno == EPIPE || errno == EBADF { return .failure ( .closed ) }

        else { return .failure ( .error ( .posix ( self, tag: "serial read" ) ) ) }
      }
    }
  }


  
  public func write ( _ data: Data, timeout: PosixPolling.Timeout = .indefinite ) -> Result<Int, SyncIO.Error> {

    guard data.count > 0 else {
      return .failure (
        .error ( .trace (self, tag: "data.count muxt be > 0" ) )
      )
    }
    
    var total_written = 0
    var timeout       = timeout
    var clock         = TimeoutClock()
    let length        = data.count

    while total_written < length {

      if let error = check ( poll.timeout ( timeout, for: .write ) ) { return .failure ( error ) }

      timeout = timeout.decrement ( elapsed: clock.elapsed() )

      let wrote : Int = data.withUnsafeBytes { buffer in
        guard let base = buffer.baseAddress else {
          errno = EFAULT
          return -1
        }

        return posix_write ( descriptor, base.advanced ( by: total_written ), length - total_written )
      }

      if wrote > 0 {
        total_written += wrote
        continue
      }

      if wrote == 0 { return .failure ( .closed ) }

      if errno != 0 {
        if errno == EINTR {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }

        if errno == EAGAIN || errno == EWOULDBLOCK {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }

        if errno == EPIPE || errno == EBADF { return .failure ( .closed ) }

        return .failure ( .error ( .posix ( self, tag: "serial write" ) ) )
      }

    }

    return .success ( total_written )
  }

  // convert a poll outcome to a SyncIO.Error (or nil, if no error)
  func check ( _ outcome: PosixPolling.PollOutcome ) -> SyncIO.Error? {
    switch outcome {
      case .ready               : return nil
      case .timeout             : return .timeout
      case .closed              : return .closed
      case .error ( let trace ) : return .error ( trace )
    }
  }
}






