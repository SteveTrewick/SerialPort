import Foundation

#if os(Linux)
import Glibc
#else
import Darwin
#endif

@_exported import Trace

public struct SerialDevice {
  public let basename : String
  public let cu       : String?
  public let tty      : String?
}



public class PortManager {


  public init() {} // god, I always foget these

  // open a port.
  // notice that I am not giving the user a choice of options, this is on purpose


  // if you already know the path ...

  public func open(path: String) -> Result<SerialPort, Trace> {

    let descriptor = posixOpen(path, O_RDWR | O_NOCTTY | O_NONBLOCK)

    if descriptor == -1 { return .failure( .posix(self, tag: "serial open") ) }
    else                { return .success( SerialPort(descriptor: descriptor)) }
  }


  // if you have an enumerated device ...
  public func open(device: SerialDevice) -> Result<SerialPort, Trace> {

    // if the device has a cu listing, we should probably use it,
    // if not, try the tty path
    if let cupath  = device.cu  { return open(path: cupath ) }
    if let ttypath = device.tty { return open(path: ttypath) }

    // if it has neither, well, that's a paddlin.
    return .failure(.trace(self, tag: "Serial port open failed, no device path"))
  }
}
