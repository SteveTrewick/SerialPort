# SerialPort

A package for opening, configuring, reading from and writing to a serial port in Swift on macOS
and Linux. It might work on iOS, dunno, haven't tried, maybe for bluetooth? Let me know if you try!

## Linux compatibility - Experimental

**Author's Note:** Linux compatibility for this package was added by a couple of 
runs through GPT Codex, which also added the below section of the README. I have 
not tested this on Linux,  only macOS. AT best I can say it definitely builds 
on the Ubuntu stack in the Codex cloud container.

### Codex Says :
Linux support is now on-par with macOS for the core APIs: you can enumerate ports,
open them via either a discovered `SerialDevice` or a direct path, and configure the
connection using the same `SerialConfig` structure. A few platform differences are
worth noting:

* **Enumeration** – on Linux the `PortManager` enumerates `/dev/tty*`, `/dev/ttyUSB*`
  and `/dev/ttyACM*` devices. macOS continues to provide both `tty.*` and `cu.*`
  style device paths. Only the paths that exist on the current platform will be
  populated on the `SerialDevice` instance.
* **Baud rates** – both platforms expose the standard baud rates declared in
  `BaudRate`. Linux exposes additional high-speed values (e.g. 230_400, 460_800,
  921_600) when the kernel reports support; macOS falls back to the Darwin termios
  table.
* **Permissions** – on most Linux distributions you must either run your process as
  root or add your user to the `dialout` (or distribution-specific) group so that it
  can open `/dev/tty*` device files. macOS generally grants access automatically but
  may prompt once for USB devices.
* **Platform-only metadata** – the optional IOKit-derived metadata (like location ID
  and vendor/product strings) on `SerialDevice` remains macOS-only, because those APIs
  depend on IOKit. Linux devices will report `nil` for those properties.



## PortManager

Start by initing a PortManager, this will aloow you to enumerate and open serial ports.

```swift

import SerialPort

let manager = PortManager()

```

If you happen to know the path of your serial port, just go ahead and

```swift
let result = manager.open(path: "/dev/cu....")

switch result {
  case .failure(let trace): // do eomthing with the error
  case .success(let port ): // prepare to fling bits
}
```

If you want to have a look see what serial ports are available on your mac, do ...

```swift

let result = manager.enumeratePorts()

switch result {
  case .failure(let trace): // do eomthing with the error
  case .success(let ports): // here is a list of SerialDevices (see below)
}

```

If this succeeds you will get an array of ```SerialDevice``` which looks like this :

```swift

[
  SerialDevice ( basename: "Bluetooth-Incoming-Port",
                  cu      : Optional("/dev/cu.Bluetooth-Incoming-Port"),
                  tty     : Optional("/dev/tty.Bluetooth-Incoming-Port")
  ),
   
  SerialDevice (
                  basename: "usbserial-142120",
                  cu      : Optional("/dev/cu.usbserial-142120"),
                  tty     : Optional("/dev/tty.usbserial-142120")
  )
]

```

Choose which one you want, ask the user, w/e, then fling it at the manager thus ...

```swift

let result = manager.open(device: device)

switch result {
  // ... you know this part already 
}

```

## Configuring

Congratulations! You are now in posession of a fully operational serial port!

Now you will need to configure it.

For brevity, I will just show you the options struct, which by default will set up as 9600 8N1, as is tradition.

```swift

public struct SerialConfig {
  public var baud     : BaudRate = .baud_9600   // default 9600 8N1, as is tradition
  public var databits : DataBits = .eight
  public var parity   : Parity   = .none
  public var stopbits : StopBits = .one
  public var linemode : LineMode = .raw
}

```

Set whatever of the available options you need and then fling them at the port instance.

```swift
port.configure(config: serialConfig)

```

If the available options aren't enough, and frankly they probably aren't at this stage, 
you can grab the existing termios config, bit bang it and send it back, thusly :

```swift

var opts = port.options

// read https://www.ing.iac.es/~docs/external/serial/serial.pdf
// ...

port.configure(options: options)

```

## Writing

This is the easy part ...

```swift

let bytes : Data = // ...

port.send(data: bytes)

```

If you actually need to know if that worked, or why it didn't ...

```swift

port.send(data: bytes) { result in 
  switch result {
    case .failure(let trace) : // do something with error
    case .success(let bytes) : // number of bytes written
  }
}

```

## Reading


You'll like this, I promise.

```swift

port.stream.handler = { result in 
  switch result {
    case .failure(let trace): // ...
    case .success(let data ): // your bytes are in here
  }
}

port.stream.resume()

// ... some time later

port.stream.cancel() {
  // whatever you need to do now that the streaming has stopped, close ports, etc
  // ...
  port.reset()
  port.close()
}

```



## Sync and Async APIs

Oh, you _didn't_ like that? Fair enough. While the above may be enough to pop up a simple 
read/write loop it needs a lot of extra plumbing to do anything especially useful so SerialPort
now offers two fairly lightweight read/write APIs one synchronous and one asynchronous.


## Synchronous I/O

Need to block the current thread until bytes arrive? Grab a `SyncIO`
helper and handle the `Result<Data, SyncIO.Error>` it returns:

```swift
let port: SerialPort = // ...
let io   = port.syncIO

switch io.read (count: 16, timeout: .seconds(2)) {
  case .success(let bytes        ): print ( "received", bytes )
  case .failure(.timeout         ): print ( "nothing arrived before the 2 second timeout" )
  case .failure(.closed          ): print ( "the other side closed the connection" )
  case .failure(.trace(let trace)): print ( "posix error", trace )
}  
```

When you omit the timeout the call blocks until bytes are ready, matching the
behavior of a plain POSIX `read`.

Need to drain everything that's currently readable? Use the timeout-based
variant to wait for the first byte and then slurp everything immediately
available:

```swift
let drained = io.read(timeout: .seconds(1))
```

Or if you're looking for a delimiter, there's a helper that keeps reading until
it arrives, with an option to retain the delimiter in the returned data:

```swift
let line = io.read(until: 0x0A, includeDelimiter: true, timeout: .seconds(1))
```

Need to push bytes out on the calling thread? Use the synchronous write helper
and handle the `Result<Int, SyncIO.Error>`:

```swift
switch io.write(Data ("OK".utf8), timeout: .seconds(1)) {
  case .success (let count        ): print ("sent", count, "bytes")
  case .failure (.timeout         ): print ("the descriptor never became writable")
  case .failure (.closed          ): print ("the peer closed before the write completed")
  case .failure (.trace(let trace)): print ("posix error", trace)
}
```

Both helpers honor the timeout (and return `.failure(.timeout)` when nothing
shows up in time) and report `.failure(.closed)` if the descriptor reaches EOF.

**NOTE** that if you are using the sync API you probably don't want anything 
wired up to the `stream.handler` or you're gonna have a bad time.


## Async I/O helper

Oh, you didn't like that _either_, OK, well.

If you prefer to work with a higher-level helper, ask the port for an `AsyncIO`
instance. It wraps the underlying stream, buffers incoming bytes, and surfaces
both asynchronous reads and writes on the queues of your choice:

There's also a convenience `io.read(timeout:completion:)` with no count or
delimiter arguments. It drains everything currently buffered as soon as you call
it, handing the accumulated bytes to the completion handler in one go. You can
still supply a timeout if you want to wait for additional bytes, and you'll get
`.failure(.timeout)` if nothing arrives in time.

```swift
let port: SerialPort = // ...
let io = port.asyncIO()

// read an exact number of bytes
io.read ( count: 8 ) { result in
  switch result {
    case .success(let bytes): print("received", bytes)
    case .failure(let error): print("read failed", error)
  }
}

// read until a newline (and include it in the returned Data)
io.read ( until: 0x0A, includeDelimiter: true ) { result in
  // handle the same way as above
}

// drain whatever is currently buffered (and optionally wait for more)
io.read { result in
  switch result {
    case .success(let bytes): print("flushed", bytes)
    case .failure(let error): print("read failed", error)
  }
}

// kick off an asynchronous write and learn how many bytes went out
io.write(Data ("hello world".utf8)) { result in
  switch result {
    case .success(let sent ): print("wrote", sent, "bytes")
    case .failure(let error): print("write failed", error)
  }
}
```

## Timeouts

All of these APIs accept an optional `SerialPort.Timeout` value. If you provide
one, the completion handler receives `.failure(.timeout)` when the deadline
passes without satisfying the request. When a timeout is omitted the read waits
until enough bytes arrive, or in the case of the no-argument read, immediately
drains and returns everything currently buffered. The write API follows the same
rules, calling back with `.failure(.timeout)` if the write does not finish before
the deadline.

You can construct timeout values using the helpers on `Timeout`, such as
`.seconds(_):`,  `.milliseconds(_)`, `.none` (equivalent to 0) or `.indefinite` 
which waits forever.

```swift
let port: SerialPort = // ...
let io = port.asyncIO()

io.read(timeout: SerialPort.Timeout.seconds(0.5)) { result in
  // handle timeout or success
}

io.write(Data([0x7F]), timeout: SerialPort.Timeout.seconds(0.5)) { result in
  // handle timeout or success
}
```



## Reset

If you need to reset the options on the port to whatever they were when you got it

```swift

port.reset()

```

## Example

I just happen to have an Arduino sitting on my USB hub that is running a banner and echo sketch,
and yes, that's the extent of my testing so far. Let's send it some data ...

```swift

import Foundation
import SerialPort


let manager = PortManager()
var serial  : SerialPort


// I happen to know the path to my Arduino, which is sat listening for incoming connections
// and echoes back anything we send it so let's just use that

switch manager.open(path: "/dev/cu.usbserial-142120") {
  case .failure(let trace): print(trace); exit(1)
  case .success(let port ): serial = port
}


// we can just use default 9600 N81, and raw mode, but let's set the opts explicitly anyway

var config = SerialConfig (
  baud    : .baud_9600,
  databits: .eight,
  parity  : .none,
  stopbits: .one,
  linemode: .raw
)

serial.configure(config: config)


// set up the handler for reading the data, like, IRL this goes somewhere
// but for the sake of demonstration, let's just print it

serial.stream.handler = { result in
  switch result {
    case .failure( let trace): print(trace); exit(1)
    case .success( let data ): print(String(data: data, encoding: .ascii) ?? "[failed]", terminator: "")
  }
}

// start chooching
serial.stream.resume()

// we'll wait a bit before we say hi, or the main loop won't have started.
// on the arduino echo program and our dispatch handler also needs some time

DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
  serial.send(data: "hi there!\n".data(using: .ascii)!) { result in
    switch result {
      case .failure(let trace): print(trace); exit(1)
      case .success(let count): print("sent \(count) bytes")
    }
  }
  
  // of course, we can just do this and not care about the error...
  serial.send ( data: "I dont care!".data(using: .ascii)! )
  
}


dispatchMain() // run 4 eva


```

That produces the following output on my console

```
CONNECT 9600
Hello! This is Arduino

Type and I will echo -> 

sent 10 bytes
hi there!
I dont care!
```

And if you're that interested, here is the Arduino code ...

```C++

#include <Arduino.h>


void setup() {
  Serial.begin(9600);
  Serial.println("CONNECT 9600\r\nHello! This is Arduino\r\n");  
  Serial.println("Type and I will echo -> \r\n");  
}

void loop() {
  while (Serial.available() > 0) {
    char byte = Serial.read();
    Serial.write(byte);
  }

}

```

## Dependencies

SerialPort depends on three other packages, all of which it will export the symbols for. 
They are [PosixInputStream](https://github.com/SteveTrewick/PosixInputStream) which 
in turn depends on [PosixError](https://github.com/SteveTrewick/PosixError) which depends
on [Trace](https://github.com/SteveTrewick/Trace) for the error handling base.
 
