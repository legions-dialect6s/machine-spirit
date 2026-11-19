import Foundation
import IOKit

// Read-only SMC ABI and known CPU/GPU sensor keys adapted from exelban/Stats, MIT.
// Copyright (c) 2019 Serhiy Mytrovtsiy. Full notice: ../Stats-LICENSE.txt.
// No fan control, privileged helper, or write operation is implemented.
final class SMCTemperatures {
  private var connection: io_connect_t = 0
  private var keys: [(String, String, UInt32, UInt32)] = []
  init() {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
    guard service != 0 else { return }
    defer { IOObjectRelease(service) }
    guard IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS else { return }
    #if arch(arm64)
      let cpu = [
        "Tp0T",
        "Te05", "Te0S", "Te09", "Te0H", "Tp01", "Tp05", "Tp09", "Tp0D", "Tp0V", "Tp0Y", "Tp0b",
        "Tp0e",
      ]
      let gpu = ["Tg0G", "Tg0H", "Tg1U", "Tg1k", "Tg0K", "Tg0L", "Tg0d", "Tg0e", "Tg0j", "Tg0k"]
    #else
      let cpu = ["TC0P"]
      let gpu: [String] = []
    #endif
    for (group, names) in [("CPU", cpu), ("GPU", gpu)] {
      for name in names {
        guard let output = call(name, operation: 9) else { continue }
        let size: UInt32 = output.withUnsafeBytes {
          $0.loadUnaligned(fromByteOffset: 28, as: UInt32.self)
        }
        let type: UInt32 = output.withUnsafeBytes {
          $0.loadUnaligned(fromByteOffset: 32, as: UInt32.self)
        }
        if (type == fourCC("flt ") && size == 4) || (type == fourCC("sp78") && size == 2) {
          keys.append((group, name, size, type))
        }
      }
    }
  }
  private func fourCC(_ name: String) -> UInt32 { name.utf8.reduce(0) { ($0 << 8) | UInt32($1) } }
  private func call(_ name: String, operation: UInt8, size: UInt32 = 0) -> [UInt8]? {
    guard connection != 0 else { return nil }
    // SMCKeyData_t's fixed C ABI is 80 bytes; explicit byte offsets avoid Swift struct packing drift.
    var input = [UInt8](repeating: 0, count: 80)
    var output = input
    input.withUnsafeMutableBytes {
      $0.storeBytes(of: fourCC(name), toByteOffset: 0, as: UInt32.self)
      $0.storeBytes(of: size, toByteOffset: 28, as: UInt32.self)
    }
    input[42] = operation
    var outputSize = 80
    let result = input.withUnsafeBytes { source in
      output.withUnsafeMutableBytes { destination in
        IOConnectCallStructMethod(
          connection, 2, source.baseAddress, 80, destination.baseAddress, &outputSize)
      }
    }
    guard result == KERN_SUCCESS, outputSize == 80, output[40] == 0 else { return nil }
    return output
  }
  func sample(only requestedGroup: String? = nil) -> [(String, Double)] {
    keys.compactMap { group, name, size, type in
      guard requestedGroup == nil || requestedGroup == group else { return nil }
      guard let output = call(name, operation: 5, size: size) else { return nil }
      let value: Double
      if type == fourCC("flt ") {
        value = Double(
          output.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 48, as: Float.self) })
      } else {
        value = Double(Int16(bitPattern: UInt16(output[48]) << 8 | UInt16(output[49]))) / 256
      }
      guard value.isFinite, value > 0, value < 150 else { return nil }
      return ("\(group) SMC \(name)", value)
    }
  }
  deinit { if connection != 0 { IOServiceClose(connection) } }
}
