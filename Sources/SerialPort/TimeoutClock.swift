
import Foundation

// it turns out that because ppoll is not available on macOS we need to do
// some manual timekeeping in case our polls, reads. writes (and if we were
// doing them, selects) encounter an EINTR or EAGAIN.

// Accuracy here is not going to be tip top, but it's good enough.

public struct TimeoutClock {
  
  var last = timespec()  // a time, obvs
  
  init () { clock_gettime(CLOCK_MONOTONIC, &last) } // set the clock at init
  
  // returns the time elapsed since init or the last time we called elapsed
  // basically a split timer
  mutating func elapsed() -> Int {
    
    var now = timespec()
    
    clock_gettime(CLOCK_MONOTONIC, &now)
    
    defer {
      last = now
    }
    // fractions of a second (which we're most likely dealing with,
    // are expressed in nanoseconds, because reasons
    return   Int((now.tv_sec  - last.tv_sec)  * 1000)
           + Int((now.tv_nsec - last.tv_nsec) / 1_000_000)
    
  }
  
}
