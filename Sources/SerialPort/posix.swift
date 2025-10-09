/*
  because bits of SerialPOrt use open and close as function names, we wrap
  posix open and close, but conditionally for macos and linux.
 
  if you think this is ugly you should have seen the way Codex tried to do it.
*/

#if os(Linux)
import Glibc
let posix_open   : (UnsafePointer<CChar>, Int32) -> Int32 = Glibc.open
let posix_close  : (Int32)                       -> Int32 = Glibc.close
let posix_read   = Glibc.read
let posix_poll   = Glibc.poll
let posix_POLLIN = Int16(Glibc.POLLIN)
#else
import Darwin
let posix_open   : (UnsafePointer<CChar>, Int32) -> Int32 = Darwin.open
let posix_close  : (Int32)                       -> Int32 = Darwin.close
let posix_read   = Darwin.read
let posix_poll   = Darwin.poll
let posix_POLLIN = Int16(Darwin.POLLIN)
#endif


