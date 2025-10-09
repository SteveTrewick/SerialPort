/*
  because bits of SerialPOrt use open and close as function names, we wrap
  posix open and close, but conditionally for macos and linux.
 
  if you think this is ugly you should have seen the way Codex tried to do it.
*/

#if os(Linux)
import Glibc
let posix_open: (UnsafePointer<CChar>, Int32) -> Int32 = Glibc.open
#else
import Darwin
let posix_open: (UnsafePointer<CChar>, Int32) -> Int32 = Darwin.open
#endif


#if os(Linux)
import Glibc
let posix_close: (Int32) -> Int32 = Glibc.close
#else
import Darwin
let posix_close: (Int32) -> Int32 = Darwin.close
#endif
