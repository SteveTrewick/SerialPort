
import Foundation
import Trace // file compiles without this, but it ought not to really.

public struct PosixPolling {
  
  
  let descriptor : Int32
  
  // model the timeout behaviour, polling is either immediate or with a timeout defined in µseconds
  public struct Timeout : Equatable {
    
    let milliseconds : Int32
    
    
    // if we indefinite, do nothing, we burn eternal
    // otherwise, subtract some millis but don't go below 0
    func decrement ( elapsed: Int ) -> Timeout {
      self == .indefinite ? .indefinite
                          : Timeout (milliseconds: Int32 ( max ( Int(milliseconds) - elapsed, 0 ) ))
    }
    
    public static var  zero       : Timeout = Timeout ( milliseconds: 0  )
    public static var  indefinite : Timeout = Timeout ( milliseconds: -1 )
    public static func wait ( _ millis: Int32 ) -> Timeout { Timeout ( milliseconds: millis ) }
  }
  
  // model the flag and tag for read/write, we use the tags for descriptive errors
  public struct Event {
    
    let flag: Int16
    let tag : String
    
    public static var read : Event = Event ( flag: posix_POLLIN,  tag: "read" )
    public static var write: Event = Event ( flag: posix_POLLOUT, tag: "write" )
  }
  
  // Outcome from calling poll_descriptor
  public enum PollOutcome {
    case ready
    case timeout
    case error(Trace)
  }
  
  // outcome of immediate polling
  public enum ImmediatePollOutcome {
    case ready
    case idle
    case error(Trace)
  }
  
  
  // MARK: Public API
  
  // poll with a timeout
  public func timeout ( _ timeout: Timeout, for event: Event ) -> PollOutcome {
    poll_descriptor ( descriptor, for: event, timeout: timeout )
  }
  
  // poll with no timeout,
  public func immediate ( for event: Event ) -> ImmediatePollOutcome {
    switch poll_descriptor ( descriptor, for: event, timeout: .zero ) {
      case .ready             : return .ready
      case .timeout           : return .idle
      case .error (let trace) : return .error(trace)
    }
  }
  
  
  // MARK: internal implmentation
  
  
  
  func poll_descriptor ( _ descriptor: Int32, for event: Event, timeout: Timeout ) -> PollOutcome {
    
    
    var state   = pollfd ( fd: descriptor, events: event.flag, revents: 0 )
    var timeout = timeout
    var clock   = TimeoutClock()
    
    while true { // blocking loop - we will exit when we get a result or timeout
      
      let status = withUnsafeMutablePointer(to: &state) {
        posix_poll ( $0, nfds_t(1), timeout.milliseconds )
      }
      
      // error reported, but ...
      if status < 0 {
        if errno == EINTR {
          // if we got interrupted, reduce the timeout so we eventually complete
          // rather than just reapplying it and hoping.
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          // milliseconds = Int32 ( max ( Int(milliseconds) - time.elapsed(since: mark), 0) )
          // mark = time.now()
          errno = 0
          continue
        }
        else
        {
          return .error ( .posix ( self, tag: event.tag ) )
        }
      }
      
      return status > 0 ? .ready : .timeout
    }
  }
  
}


//public struct PosixTimeElapsed {
//
//  // get a time
//  public func now() -> timespec {
//    var t = timespec()
//    clock_gettime(CLOCK_MONOTONIC, &t)
//    return t
//  }
//
//  // time elapsed in µseconds
//  public func elapsed ( since: timespec ) -> Int {
//    var now = timespec()
//    clock_gettime(CLOCK_MONOTONIC, &now)
//    return Int((now.tv_sec  - since.tv_sec)  * 1000) + Int((now.tv_nsec - since.tv_nsec) / 1_000_000)
//  }
//}

public struct TimeoutClock {
  
  var last = timespec()
  
  init () {
    clock_gettime(CLOCK_MONOTONIC, &last)
  }
  
  
  mutating func elapsed() -> Int {
    
    var now = timespec()
    
    clock_gettime(CLOCK_MONOTONIC, &now)
    
    defer {
      last = now
    }
    return Int((now.tv_sec  - last.tv_sec)  * 1000) + Int((now.tv_nsec - last.tv_nsec) / 1_000_000)
    
  }
}


public struct SyncIO {
  
  public enum Error: Swift.Error {
     case timeout
     case closed
     case error(Trace)
  }
  
  
  
  let descriptor : Int32
  let poll       : PosixPolling
  
  public init ( descriptor : Int32 ) {
    self.descriptor = descriptor
    self.poll       = PosixPolling(descriptor: descriptor)
  }
  

  
  public func read ( count: Int, timeout: PosixPolling.Timeout = .indefinite ) -> Result<Data, SyncIO.Error> {

    if count == 0 { return .success ( Data() ) }

    // bail if we have a dumb parameter, how ya gonna read -12 bytes, dumbass
    guard count > 0 else {
      return .failure (
        .error( .trace ( self, tag: "read count must be > 0" ) )
      )
    }
    
    var buffer  = [UInt8](repeating: 0, count: count)
    var timeout = timeout
    var clock   = TimeoutClock()
    
    while true {
      //let remaining = PosixPolling.Timeout(milliseconds: milliseconds)
      if let error = check ( poll.timeout(timeout, for: .read) ) { return .failure(error) }
      
      let bytes_read = buffer.withUnsafeMutableBytes { buffer in
        posix_read ( descriptor, buffer.baseAddress, count )
      }
      
      if bytes_read >= 0 {
        return bytes_read > 0 ? .success ( Data ( bytes: buffer, count: bytes_read ) )
                              : .failure ( .closed )
      }
      
      if errno != 0 {
        if errno == EINTR {
          timeout = timeout.decrement(elapsed: clock.elapsed() )
//          milliseconds = Int32 ( max ( Int(milliseconds) - time.elapsed(since: mark), 0) )
//          mark = time.now()
          errno = 0
          continue
        }
        else { return  .failure( .error(.posix(self, tag: "serial read")) ) }
      }
      
      
    }
  }
  
  
  
  
  public func read ( timeout: PosixPolling.Timeout = .indefinite, maxbuffer: Int = 1024 ) -> Result<Data, SyncIO.Error> {
    
    
    //var milliseconds = timeout.milliseconds
    var collected    = [UInt8]()
    var should_wait  = true
    var buffer       = [UInt8](repeating: 0, count: maxbuffer)
    var timeout      = timeout
    var clock        = TimeoutClock()
    
    
    while true {
      // we should wait if : 1) this is the first go around. 2) we encounter EINTR during read
      if should_wait {
        //let remaining = PosixPolling.Timeout(milliseconds: milliseconds)
        if let error = check ( poll.timeout(timeout, for: .read) ) { return .failure(error) }
      }
      // otherwise we should poll the descriptor with no timeout
      else {
        switch poll.immediate ( for: .read ) {
          case .ready               : break                               // descriptor is ready, try and read some bytes, see below
          case .idle                : return .success ( Data(collected) ) // descriptor is idle, we have finished
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
        else { return .failure(.error(.posix(self, tag: "serial read"))) }
      }
      
      if bytes_read == 0 { return .failure(.closed) }
      else {
        collected.append(contentsOf: buffer[0..<bytes_read])
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
      if let error = check ( poll.timeout(timeout, for: .read) ) { return .failure(error) }
      
      timeout = timeout.decrement ( elapsed: clock.elapsed() )
      //if timeout == .zero { return .failure (.timeout) }
      
      var byte : UInt8 = 0
      let bytes_read = withUnsafeMutablePointer(to: &byte) {
        posix_read ( descriptor, $0, 1 )
      }

      if bytes_read > 0 {
        collected.append ( byte )

        if byte == delimiter {
          if !includeDelimiter { collected.removeLast() }
          return .success ( Data ( collected ) )
        }

        continue
      }

      if bytes_read == 0 { return .failure ( .closed ) }

      if errno != 0 {
        if errno == EINTR {
          timeout = timeout.decrement ( elapsed: clock.elapsed() )
          errno = 0
          continue
        }
        else { return .failure ( .error ( .posix ( self, tag: "serial read" ) ) ) }
      }
    }
  }


  
  public func write ( _ data: Data, timeout: PosixPolling.Timeout = .indefinite ) -> Result<Int, SyncIO.Error> {

    if data.isEmpty { return .success ( 0 ) } //TODO: this is an error, not a success

    return data.withUnsafeBytes { buffer -> Result<Int, SyncIO.Error> in
      guard let base = buffer.baseAddress else { return .success ( 0 ) }

      var total_written = 0
      var timeout       = timeout
      var clock         = TimeoutClock()
      let length        = buffer.count

      while total_written < length {
        
        if let error = check ( poll.timeout ( timeout, for: .write ) ) { return .failure ( error ) }
        
        timeout = timeout.decrement ( elapsed: clock.elapsed() )
        //if timeout == .zero { return .failure(.timeout) }
        
        let wrote = posix_write ( descriptor, base.advanced ( by: total_written ), length - total_written )

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
  }

  // convert a poll outcome to a SyncIO.Error (or nil, if no error)
  func check ( _ outcome: PosixPolling.PollOutcome ) -> SyncIO.Error? {
    switch outcome {
      case .ready               : return nil
      case .timeout             : return .timeout
      case .error ( let trace ) : return .error ( trace )
    }
  }
}



