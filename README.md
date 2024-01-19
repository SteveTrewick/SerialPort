# SerialPort

A package for opening, configuring, reading from and writing to a serial port in Swift on macOS, 
it might work on iOS, dunno, haven't tried, maybe for bluetooth? Won't work on linux as is.


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
