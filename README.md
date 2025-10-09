# SerialPort

A package for opening, configuring, reading from and writing to a serial port in Swift on macOS
and Linux. It might work on iOS, dunno, haven't tried, maybe for bluetooth.

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

### Quick start on Linux

If you already know the path of your serial interface, you can open it directly:

```swift
import SerialPort

let manager = PortManager()

switch manager.open(path: "/dev/ttyUSB0") {
case .failure(let trace):
  print("failed to open port", trace)
case .success(let port):
  try? port.configure(config: SerialConfig(baud: .baud_115200))
  // use `port` like you would on macOS
}
```

Or, discover available ports and pick one by basename:

```swift
let result = PortManager().enumeratePorts()

if case let .success(devices) = result,
   let device = devices.first(where: { $0.basename == "ttyUSB0" }) {
  _ = PortManager().open(device: device)
}
```

### Troubleshooting on Linux

* `POSIXError.permissionDenied` – confirm your user is in the `dialout` (Debian/Ubuntu),
  `uucp` (Arch), or `serial` (RHEL/Fedora) group, then log out/in. As a temporary
  workaround you can run the process with elevated privileges.
* `POSIXError.deviceBusy` – another process (like ModemManager) may have the port open.
  Disable or stop the service, or unplug/replug the device to release the handle.
* No ports are enumerated – check that your user has permissions and that the device is
  exposed via `/dev/ttyUSB*` or `/dev/ttyACM*`. Some boards appear as `/dev/ttyS*` and
  require passing the full path to `open(path:)`.

## Termios
This is an incomplete implementation as of the yet, particularly with regards to the full 
set of termios options and is highly experimental. Honestly, this whole thing got way out 
of hand while I was just building something tofling a couple of bytes at an Arduino so that 
I can trigger a radio PTT. You can directly specify termios options through `port.configure` 
as shown below. 
 

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

If this succedds (and it should) you will get an array of ```SerialDevice``` which looks like this :

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

For brevity, I will just show you the options struct, which by default will set up as 9600 8N1, as is tradition

```swift

public struct SerialConfig {
  public var baud     : BaudRate = .baud_9600   // default 9600 8N1, as is tradition
  public var databits : DataBits = .eight
  public var parity   : Parity   = .none
  public var stopbits : StopBits = .one
  public var linemode : LineMode = .raw
}

```

Set whatever of the available options you need and then fling them at the port instance

```swift
port.configure(config: serialConfig)

```

If the available options aren't enough, and frankly they probably aren't at this stage, 
you can grab the existing termios config, bit bang it and send it back, thusly

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


## Buffered reading

Oh, you didn't like that, OK, well.

If you prefer to read from the port without wiring up your own stream handler, wrap
the stream with a buffered reader:

```swift
let port: SerialPort = // ...
let reader = port.makeBufferedReader()

// read an exact number of bytes
reader.read(count: 8) { result in
  switch result {
    case .success(let bytes):
      print("received", bytes)
    case .failure(let error):
      print("read failed", error)
  }
}

// read until a newline (and include it in the returned Data)
reader.read(until: 0x0A, includeDelimiter: true) { result in
  // handle the same way as above
}
```

Both APIs accept an optional `DispatchTimeInterval` timeout. If you provide one,
the completion handler receives `.failure(.timeout)` when the deadline passes
without satisfying the request. When a timeout is omitted the read waits until
enough bytes arrive.



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
    case .failure(let trace) : print(trace); exit(1)
    case .success(let data ) : print( String(data: data, encoding: .ascii) ?? "[failed]", terminator: "" )
  }
}

// start chooching
serial.stream.resume()

// we'll wait a bit before we say hi, or the main loop won't have started.
// on the arduino echo program and our dispatch handler also needs some time

DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
  serial.send(data: "hi there!\n".data(using: .ascii)! ) { result in
    switch result {
      case .failure(let trace) : print(trace); exit(1)
      case .success(let count) : print("sent \(count) bytes")
    }
  }
  
  // of course, we can just do this and not care about the error...
  serial.send(data: "I dont care!".data(using: .ascii)!)
  
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
 
