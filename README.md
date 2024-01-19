# SerialPort

A package for opening, configuring, reading from and writing to a serial port in Swift on macOS, 
it might work on iOS, dunno, haven't tried, maybe for bluetooth? Won't work on linux as is.


This is an incomplete implementation as of the yet, particularly with regards to the full set of termios options
and is highly experimental. Honestly, this whole thing got way out of hand while I was just building something to
fling a couple of bytes at an Arduino so that I can trigger a radio PTT.
 

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

## Reset

If you need to reset the options on the port to ehatever they were when you got it

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
 
