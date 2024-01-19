import Foundation
import PosixInputStream


 

public class SerialPort {
  
  
  public  let descriptor  : Int32
  private let operationQ = DispatchQueue(label: "SerialPortOpQ")
  
  
  private(set) public var options      = termios()
                      var origoptions  = termios()
  
  
  public let stream : PosixInputStream  // yes, yes I did just expose that as an API.
  
  
  
  
  public init(descriptor: Int32) {
    
    self.descriptor = descriptor
    
    tcgetattr(descriptor, &origoptions)
    tcgetattr(descriptor, &options)
    
    stream = PosixInputStream(descriptor: descriptor, targetQueue: operationQ)
  }
  
  
  
  // bung a config struct in here with your selected options
  
  public func configure(config: SerialConfig) {
    
    cfsetspeed(&options, config.baud.speed)
    
    
    options.c_cflag &= ~UInt(CSIZE)
    options.c_cflag |= config.databits.count
    
    
    switch config.parity {
      case .none :
        options.c_cflag &= ~UInt(PARENB)
        
      case .even :
        options.c_cflag |=  UInt(PARENB)
        options.c_cflag &= ~UInt(PARODD)
                   
      case .odd  :
        options.c_cflag |= UInt(PARENB)
        options.c_cflag |= UInt(PARODD)
    }
    
    
    switch config.stopbits {
      case .one : options.c_cflag &= ~UInt(CSTOPB)
      case .two : options.c_cflag |=  UInt(CSTOPB)
    }
    
    
    switch config.linemode {
      case .canonical : options.c_lflag |=  ( UInt(ICANON) | UInt(ECHO) | UInt(ECHOE) )
      case .raw       : options.c_lflag &= ~( UInt(ICANON) | UInt(ECHO) | UInt(ECHOE) | UInt(ISIG) )
    }
    
    // always, don't @ me : https://www.ing.iac.es/~docs/external/serial/serial.pdf
    options.c_cflag |= tcflag_t(CREAD | CLOCAL)
    
    
    tcsetattr(descriptor, TCSANOW, &options)
  }
  
  
  
  // until we add the rest of the config opts, we can bounce through
  // termios, but if you find yourself doing this, you should be adding
  // proper config opts. m'kay?
  
  public func ocnfigure(options: termios) {
    var options = options
    tcsetattr(descriptor, TCSANOW, &options)
  }
  
  
  
  public func close() {
    
    self.reset()              // just in case
    
    Darwin.close(descriptor)  // technically this returns a vaule, but there's
                              // SFA we can do about it if it doesn't work. close more?
  }
  
  
  
  // reset by applying the original settings that the port came with
  
  public func reset() {
    tcsetattr(descriptor, TCSANOW, &origoptions)
  }
  
  
  
  // send data, duh, apply a completion hamdelr if you need to know why its not working,
  
  public func send( data: Data, complete: ((Result<Int, Trace>) -> Void)? = nil ) {
    
    operationQ.async { [self] in
      
      data.withUnsafeBytes {
        
        let wrote = write(descriptor, $0.baseAddress, data.count)
        
        if wrote == -1 {
            complete?( .failure( .posix(self, tag: "serial write") ) )
        }
        else { complete?(.success(wrote)) }
      }
    }
  }
  
  // yes, there is no read, that happens through the stream. see README.md
}

