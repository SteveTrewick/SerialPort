
import Foundation

public struct PosixPolling {
  
  
  let descriptor : Int32
  
  // model the timeout behaviour, polling is either immediate or with a timeout defined in µseconds
  public struct Timeout {
    
    let milliseconds : Int32
    
    public static var  none : Timeout = Timeout ( milliseconds: 0 )
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
    switch poll_descriptor(descriptor, for: event, timeout: .none) {
      case .ready             : return .ready
      case .timeout           : return .idle
      case .error (let trace) : return .error(trace)
    }
  }
  
  
  // MARK: internal implmentation
  
  let time = PosixTimeElapsed()
  
  func poll_descriptor ( _ descriptor: Int32, for event: Event, timeout: Timeout ) -> PollOutcome {
    
    var milliseconds = timeout.milliseconds
    
    
    // create a polling struct for the descriptors and events we want to poll
    var state = pollfd ( fd: descriptor, events: event.flag, revents: 0 )
    let start = time.now()
    
    while true { // blocking loop - we will exit when we get a result or timeout
      
      let status = withUnsafeMutablePointer(to: &state) {
        posix_poll ( $0, nfds_t(1), milliseconds )
      }
      
      // error reported, but ...
      if status < 0 {
        if errno == EINTR {
          // if we got interrupted, reduce the timeout so we eventually complete
          // rather than just reapplying it and hoping.
          milliseconds = Int32 ( max ( Int(milliseconds) - time.elapsed(since: start), 0) )
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


public struct PosixTimeElapsed {
  
  // get a time
  public func now() -> timespec {
    var t = timespec()
    clock_gettime(CLOCK_MONOTONIC, &t)
    return t
  }
  
  // time elapsed in µseconds
  public func elapsed ( since: timespec ) -> Int {
    var now = timespec()
    clock_gettime(CLOCK_MONOTONIC, &now)
    return Int((now.tv_sec  - since.tv_sec)  * 1000) + Int((now.tv_nsec - since.tv_nsec) / 1_000_000)
  }
}

public struct SyncIO {
  
  public enum Error: Swift.Error {
     case timeout
     case closed
     case error(Trace)
  }
  
  let time       = PosixTimeElapsed()
  let descriptor : Int32
  let poll       : PosixPolling
  
  public init ( descriptor : Int32 ) {
    self.descriptor = descriptor
    self.poll       = PosixPolling(descriptor: descriptor)
  }
  

  
  public func read ( count: Int, timeout: PosixPolling.Timeout = .none ) -> Result<Data, SyncIO.Error> {
  
    // bail if we have a dumb parameter, how ya gonna read -12 bytes, dumbass
    guard count > 0 else {
      return .failure (
        .error( .trace ( self, tag: "read count must be > 0" ) )
      )
    }
    
    var buffer = [UInt8](repeating: 0, count: count)
    let start        = time.now()
    var milliseconds = timeout.milliseconds
    
    while true {
      let remaining = PosixPolling.Timeout(milliseconds: milliseconds)
      if let error = check ( poll.timeout(remaining, for: .read) ) { return .failure(error) }
      
      let bytes_read = buffer.withUnsafeMutableBytes { buffer in
        posix_read ( descriptor, buffer.baseAddress, count )
      }
      
      if errno != 0 {
        if errno == EINTR {
          milliseconds = Int32 ( max ( Int(milliseconds) - time.elapsed(since: start), 0) )
          errno = 0
          continue
        }
        else { return  .failure( .error(.posix(self, tag: "serial read")) ) }
      }
      
      return bytes_read > 0 ? .success ( Data ( bytes: buffer, count: bytes_read ) )
                            : .failure ( .closed )
    }
  }
  
  
  
  
  public func read ( timeout: PosixPolling.Timeout = .none, maxbuffer: Int = 1024 ) -> Result<Data, SyncIO.Error> {
    
    
    var milliseconds = timeout.milliseconds
    var collected    = [UInt8]()
    var should_wait  = true
    var buffer       = [UInt8](repeating: 0, count: maxbuffer)
    let start        = time.now()
    
    
    while true {
      // we should wait if : 1) this is the first go around. 2) we encounter EINTR during read
      if should_wait {
        let remaining = PosixPolling.Timeout(milliseconds: milliseconds)
        if let error = check ( poll.timeout(remaining, for: .read) ) { return .failure(error) }
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
          milliseconds = Int32 ( max ( Int(milliseconds) - time.elapsed(since: start), 0) )
          should_wait = true
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
  
  // convert a poll outcome to a SyncIO.Error (or nil, if no error)
  func check ( _ outcome: PosixPolling.PollOutcome ) -> SyncIO.Error? {
    switch outcome {
      case .ready               : return nil
      case .timeout             : return .timeout
      case .error ( let trace ) : return .error ( trace )
    }
  }
}



