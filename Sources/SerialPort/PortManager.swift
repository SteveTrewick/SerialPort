
import Foundation

import IOKit
import IOKit.serial

import Trace


public class TTYManager {
  
  
  // open a port.
  // notice that I am not giving the user a choice of options, this is on purpose

  
  // if you already know the path ...
  
  public func open(path: String) -> Result<TTY, Trace> {
    
    let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
    
    if descriptor == -1 { return .failure( .posix(self, tag: "serial open") ) }
    else                { return .success( TTY(descriptor: descriptor)) }
  }
  
  
  // if you have an enumerated device ...
  public func open(device: SerialDevice) -> Result<TTY, Trace> {
    
    // if the device has a cu listing, we should probably use it,
    // if not, try the tty path
    if let cupath  = device.cu  { return open(path: cupath ) }
    if let ttypath = device.tty { return open(path: ttypath) }
    
    // if it has neither, well, that's a paddlin.
    return .failure(.trace(self, tag: "Serial port open failed, no device path"))
  }
  
  /*
    OK, strap in.
      1) We use IOKit to enumerate serial ports, this will not work on linux.
         If you need linux compat, either use one of the many (two?) other swift
         packages or feel free to add it. On macOS and especially iOS, there's
         basically no chance we get anywjere near the /dev/ path hierarchy
   
      2) There will be those who say "but Steve [it me!], IOKit won't work with
         muh virtual TTY cuz only muh /dev/cu*. This is not true, as we will see,
         its just that the devs who used IOKit to do this only knew one const and were
         to fucking lazy to look up the others. Go ahead, @ me
   
      3) Seriously though, if your use case is linux or virtual TTYs you probably
         want to find a better, more mature, less idiosyncratic (sp?) package
         rather than I hacked up to cock about with for fun on Frday nights while
         I'm drunk.
   
      4) Anyhooo ...
  */
  
  public func enumeratePorts() -> Result<[SerialDevice], Trace> {
    
    var iterator : io_iterator_t  = 0
    var devices  : [SerialDevice] = []
    var device   : io_object_t
    
    let result = IOServiceGetMatchingServices (
                    kIOMasterPortDefault,
                    IOServiceMatching(kIOSerialBSDServiceValue),
                    &iterator
                 )
    
    if result == KERN_FAILURE { return .failure(.trace(self, tag: "IOKit matching : \(result)")) }
    
    repeat {
      device = IOIteratorNext(iterator)
      if device != 0 {
        
        // if there is no base name, we might as well ignore it.
        if let base = IORegistryEntryCreateCFProperty(device, "IOTTYDevice" as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String {
          devices.append (
            SerialDevice (
              basename: base,
              // yes, fantasically, these consts are not imported into swift by IOKit,
              // we could use a bridging header but I am long since past touching Obj C
              // and these appear precisely once, here, so, eh. They won't change. Probably.
              // notice that we pull both the cu and tty, so if your device is virtual,
              // you will still see it in the list. m'kay?
              cu      : IORegistryEntryCreateCFProperty(device, "IOCalloutDevice" as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String,
              tty     : IORegistryEntryCreateCFProperty(device, "IODialinDevice"  as CFString, kCFAllocatorDefault, 0).takeRetainedValue() as? String
            )
            // what? get a bigger monitor.
          )
        }
      }
    } while device != 0
    
    return .success(devices)
  }
}
