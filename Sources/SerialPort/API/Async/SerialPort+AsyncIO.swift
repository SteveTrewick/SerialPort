
import Foundation

public extension SerialPort {

  func asyncIO(callbackQueue: DispatchQueue? = nil) -> AsyncIO {

    let existingHandler = stream.handler

    return AsyncIO(serialPort: self,
                   callbackQueue: callbackQueue,
                   forwardingHandler: existingHandler)
  }
}
