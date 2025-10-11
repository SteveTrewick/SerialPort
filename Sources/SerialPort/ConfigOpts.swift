import Foundation
#if os(Linux)
import Glibc
#else
import Darwin
#endif

/*
  Serial port config options
  
  Please note that this is *not* complete and may never be,
  options will be added as I (or indeed you, dear reader!) need them
 
  Probably the next set we *really* need are the CRLF translations,
  though I have a feeling they may not work anyway in raw mode.
  
*/


// well, this is much stupider than it needs to be
// these consts are imported, but we can (AFAIK) only use these values
// and we have to use literals for our enum initialisation, not consts

// still, this way we get a CaseIterable that we can use in a list
// and better autocomplete, copy copy, pasty pasty.

public enum BaudRate : CaseIterable {
    case baud_0
    case baud_50
    case baud_75
    case baud_110
    case baud_134
    case baud_150
    case baud_200
    case baud_300
    case baud_600
    case baud_1200
    case baud_1800
    case baud_2400
    case baud_4800
#if !os(Linux)
    // Intermediate baud rates such as 7200 are Darwin-specific and are not exposed on Linux.
    case baud_7200
#endif
    case baud_9600
    case baud_19200
    case baud_38400
#if !os(Linux)
    case baud_14400
    case baud_28800
#endif
    case baud_57600
#if !os(Linux)
    case baud_76800
#endif
    case baud_115200
    case baud_230400
  
  
    public var speed : speed_t {
        switch self {
            case .baud_0      : return speed_t(B0)
            case .baud_50     : return speed_t(B50)
            case .baud_75     : return speed_t(B75)
            case .baud_110    : return speed_t(B110)
            case .baud_134    : return speed_t(B134)
            case .baud_150    : return speed_t(B150)
            case .baud_200    : return speed_t(B200)
            case .baud_300    : return speed_t(B300)
            case .baud_600    : return speed_t(B600)
            case .baud_1200   : return speed_t(B1200)
            case .baud_1800   : return speed_t(B1800)
            case .baud_2400   : return speed_t(B2400)
            case .baud_4800   : return speed_t(B4800)
#if !os(Linux)
            case .baud_7200   : return speed_t(B7200)
#endif
            case .baud_9600   : return speed_t(B9600)
            case .baud_19200  : return speed_t(B19200)
            case .baud_38400  : return speed_t(B38400)
#if !os(Linux)
            case .baud_14400  : return speed_t(B14400)
            case .baud_28800  : return speed_t(B28800)
#endif
            case .baud_57600  : return speed_t(B57600)
#if !os(Linux)
            case .baud_76800  : return speed_t(B76800)
#endif
            case .baud_115200 : return speed_t(B115200)
            case .baud_230400 : return speed_t(B230400)
        }
    }
  
}

// same oh, same oh, in fact, there's going to a bit more of this as we go innit?

public enum DataBits : Int32, CaseIterable {
  
  case five
  case six
  case seven
  case eight
  
  public var count : tcflag_t {
    switch self {
      case .five  : return tcflag_t(CS5)
      case .six   : return tcflag_t(CS6)
      case .seven : return tcflag_t(CS7)
      case .eight : return tcflag_t(CS8)
    }
  }
}

// this one is trickier to set, combo of bits
public enum Parity : CaseIterable {
  case none
  case even
  case odd
}

// this one is a set or unset jobby, so no raw values
public enum StopBits : CaseIterable {
  case one
  case two
}

public enum LineMode {
  case canonical, raw
}

// now we bundle them up into here

public struct SerialConfig {
  
  public var baud     : BaudRate = .baud_9600   // default 9600 8N1, as is tradition
  public var databits : DataBits = .eight
  public var parity   : Parity   = .none
  public var stopbits : StopBits = .one
  public var linemode : LineMode = .raw
  
  public init() {}
  
  public init(baud: BaudRate, databits: DataBits, parity: Parity, stopbits: StopBits, linemode: LineMode) {
    self.baud     = baud
    self.databits = databits
    self.parity   = parity
    self.stopbits = stopbits
    self.linemode = linemode
  }
  
}
