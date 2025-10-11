

import Foundation

// extend us on to the SerialPort
public extension SerialPort {

  /// A synchronous I/O helper bound to this serial port descriptor.
  var syncIO : SyncIO { SyncIO ( descriptor: descriptor ) }
}
