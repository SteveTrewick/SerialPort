
import Foundation
import Trace


// wrapper around posix poll that makes up for macos not having ppoll

/// Provides polling helpers for POSIX file descriptors on platforms without `ppoll`.
public struct PosixPolling {
  
  
  let descriptor : Int32

  // model the timeout behaviour, polling is either immediate or with a timeout defined in µseconds
  /// Represents a poll timeout in milliseconds, including convenience constructors.
  public struct Timeout : Equatable {

    let milliseconds : Int32
    

    // if we indefinite, do nothing, we burn eternal
    // otherwise, subtract some millis but don't go below 0
    /// Reduces the timeout by the elapsed duration while respecting indefinite waits.
    ///
    /// - Parameter elapsed: The number of milliseconds that have already passed.
    /// - Returns: A new timeout value adjusted for the elapsed time.
    func decrement ( elapsed: Int ) -> Timeout {
      self == .indefinite ? .indefinite
                          : Timeout (milliseconds: Int32 ( max ( Int(milliseconds) - elapsed, 0 ) ))
    }
    
    
    // MARK: Convenience constructors
    
    public static var  zero       : Timeout = Timeout ( milliseconds:  0 )
    public static var  indefinite : Timeout = Timeout ( milliseconds: -1 )
    /// Creates a timeout that waits for the specified number of milliseconds.
    ///
    /// - Parameter millis: The number of milliseconds to wait before giving up.
    /// - Returns: A timeout representing the requested delay.
    public static func wait ( _ millis: Int32 ) -> Timeout { Timeout ( milliseconds: millis ) }

    
    // I actually don't like this because you can multiply x 1000 in your head,
    // but codex has added it as a last act of defiance. Anyway, have some seconds.
    /// Creates a timeout from a `TimeInterval`, rounding up to the nearest millisecond.
    ///
    /// - Parameter interval: The interval, in seconds, to convert to a timeout.
    /// - Returns: A timeout that waits approximately the specified number of seconds.
    public static func seconds ( _ interval: TimeInterval ) -> Timeout {

      if interval.isInfinite { return .indefinite }
      if interval <= 0       { return .zero }

      let milliseconds = Int ( ( interval * 1000 ).rounded (.up) )
      let clamped      = min ( Int ( Int32.max ), milliseconds )

      return .wait ( Int32 ( clamped ) )
    }
  }
  
  

  // model the flag and tag for read/write, we use the tags for descriptive errors
  /// Represents a pollable event, describing the POSIX flag and a descriptive tag.
  public struct Event {
    
    let flag: Int16
    let tag : String
    
    public static var read : Event = Event ( flag: posix_POLLIN,  tag: "read" )
    public static var write: Event = Event ( flag: posix_POLLOUT, tag: "write" )
  }
  

  // Outcome from calling poll_descriptor
  /// Represents the outcome when polling with a timeout.
  public enum PollOutcome {
    case ready
    case timeout
    case closed
    case error(Trace)
  }

  // outcome of immediate polling
  /// Represents the outcome when polling without a timeout.
  public enum ImmediatePollOutcome {
    case ready
    case idle
    case closed
    case error(Trace)
  }
  
  
  // MARK: Public API
  
  // poll with a timeout
  /// Polls the descriptor for the specified event, waiting up to the provided timeout.
  ///
  /// - Parameters:
  ///   - timeout: The maximum amount of time to wait for the event.
  ///   - event: The readiness event to monitor on the descriptor.
  /// - Returns: The outcome of polling for the requested event.
  public func timeout ( _ timeout: Timeout, for event: Event ) -> PollOutcome {
    poll_descriptor ( descriptor, for: event, timeout: timeout )
  }
  
  // poll with no timeout,
  /// Polls the descriptor for the specified event without waiting.
  ///
  /// - Parameter event: The readiness event to probe immediately on the descriptor.
  /// - Returns: The outcome when polling without allowing the descriptor to block.
  public func immediate ( for event: Event ) -> ImmediatePollOutcome {
    switch poll_descriptor ( descriptor, for: event, timeout: .zero ) {
      case .ready             : return .ready
      case .timeout           : return .idle
      case .closed            : return .closed
      case .error (let trace) : return .error(trace)
    }
  }
  
  
  // MARK: internal implmentation
  


  /// Performs the core polling operation, retrying on transient POSIX errors.
  ///
  /// - Parameters:
  ///   - descriptor: The file descriptor to monitor for readiness.
  ///   - event: The readiness event to wait for.
  ///   - timeout: The maximum amount of time to wait for the event.
  /// - Returns: The resulting outcome after polling with the supplied parameters.
  func poll_descriptor ( _ descriptor: Int32, for event: Event, timeout: Timeout ) -> PollOutcome {
    
    /*
      there is, sadly, no ppoll on macOS (or BSD, I think) so we need to do some manual
      timekeeping here. EINTR, EAGAIN or EWOULDBLOCK can all cause our poll to exit
      before the timeout is done and we might miss the descriptor becoming ready,
      especially if timeout == .indefinite and we don't want that.
     
      If we encounter one of these errors we loop and retry - *but* we burn some of
      the timeout instead of blindly reapplying it so we don't get stuck forever or
      for much longer than we sepcified.
    */
    
    var state   = pollfd ( fd: descriptor, events: event.flag, revents: 0 )
    var timeout = timeout
    var clock   = TimeoutClock()
    
    while true { // blocking loop - we will exit when we get a result or timeout
      
      let status = withUnsafeMutablePointer(to: &state) {
        posix_poll ( $0, nfds_t(1), timeout.milliseconds )
      }
      
      // error reported, but ...
      if status < 0 {
        // we go again
        if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
          timeout = timeout.decrement ( elapsed: clock.elapsed() ) // so we can't loop forever
          errno   = 0                                              // clear the error
          continue
        }

        // we go home
        if errno == EBADF || errno == EPIPE {
          errno = 0
          return .closed // rude!
        }

        // we go home with a mystery box
        return .error ( .posix ( self, tag: event.tag ) )
      }

      // we made but ...
      return status > 0 ? .ready       // yay
                        : .timeout     // boooo
    }
  }
  
}
