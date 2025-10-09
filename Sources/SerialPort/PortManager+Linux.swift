#if os(Linux)
import Foundation

extension PortManager {

  public func enumeratePorts() -> Result<[SerialDevice], Trace> {

    let prefixes = [
      "ttyS",    // PC serial ports
      "ttyUSB",  // USB serial adapters
      "ttyACM",  // CDC ACM devices
      "ttyAMA",  // serial console on Raspberry Pi
      "ttyPS",   // Xilinx PS UART
      "ttyXR",   // Exar devices
      "rfcomm",  // bluetooth serial
      "ttyMI",   // various multiport cards
      "ttyGS"    // USB gadget serial
    ]

    do {

      let entries = try FileManager.default.contentsOfDirectory(atPath: "/dev")

      let devices = entries
        .filter { entry in prefixes.contains { prefix in entry.hasPrefix(prefix) } }
        .sorted()
        .map { entry -> SerialDevice in
          let path = "/dev/\(entry)"
          return SerialDevice(basename: entry, cu: nil, tty: path)
        }

      return .success(devices)
    }
    catch {
      return .failure(.trace(self, tag: "Linux device scan failed: \(error.localizedDescription)"))
    }
  }
}
#endif
