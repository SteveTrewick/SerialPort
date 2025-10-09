
import Foundation

public extension SerialPort {

  func bufferedReader(callbackQueue: DispatchQueue? = nil) -> SerialBufferedReader {

    let existingHandler = stream.handler

    return SerialBufferedReader(serialPort: self,
                                callbackQueue: callbackQueue,
                                forwardingHandler: existingHandler)
  }
}
