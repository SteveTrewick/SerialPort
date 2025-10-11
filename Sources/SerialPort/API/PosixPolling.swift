
import Foundation
import Trace


// wrapper around posix poll that makes up for macos not having ppoll

/// Provides polling helpers for POSIX file descriptors on platforms without `ppoll`.
public struct PosixPolling {


  let descriptor : Int32
  
  

  
  /// Represents a pollable event, describing the POSIX flag and a descriptive tag.
  public struct Event {
    
    let flag: Int16
    let tag : String
    
    public static var read : Event = Event ( flag: posix_POLLIN,  tag: "read" )
    public static var write: Event = Event ( flag: posix_POLLOUT, tag: "write" )
  }
  

  
  /// Represents the outcome when polling with a timeout.
  public enum PollOutcome {
    case ready
    case timeout
    case closed
    case error(Trace)
  }

  
  /// Represents the outcome when polling without a timeout.
  public enum ImmediatePollOutcome {
    case ready
    case idle
    case closed
    case error(Trace)
  }
  
  
  // MARK: Public API
  
  
  /// Polls the descriptor for the specified event, waiting up to the provided timeout.
  ///
  /// - Parameters:
  ///   - timeout: The maximum amount of time to wait for the event.
  ///   - event: The readiness event to monitor on the descriptor.
  /// - Returns: The outcome of polling for the requested event.
  
  public func timeout ( _ timeout: Timeout, for event: Event ) -> PollOutcome {
    poll_descriptor ( descriptor, for: event, timeout: timeout )
  }
  
  
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
  
  
  // MARK: internal implementation
  


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
      for much longer than we specified.
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
