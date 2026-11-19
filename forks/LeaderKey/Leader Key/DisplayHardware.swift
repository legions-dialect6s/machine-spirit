// Registry matching and DDC protocol adapted from MonitorControl's Arm64DDC.swift:
// https://github.com/MonitorControl/MonitorControl/blob/main/MonitorControl/Support/Arm64DDC.swift
// Copyright © MonitorControl. @JoniVR, @theOneyouseek, @waydabber and others
// MIT License — Copyright © 2017
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.

import Cocoa
import Darwin
import IOKit
import os.log

/// Each instance belongs to one serial hardware queue. Keep dlopen handles
/// alive for the process lifetime: cached function pointers must never dangle.
final class DisplayHardware {
  typealias GetBrightness = @convention(c) (UInt32, UnsafeMutablePointer<Float>) -> Int32
  typealias SetBrightness = @convention(c) (UInt32, Float) -> Int32
  typealias CreateService = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
  typealias Transfer =
    @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> Int32
  typealias DisplayInfo = @convention(c) (UInt32) -> Unmanaged<CFDictionary>?

  private let displayServices = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices", RTLD_LAZY)
  private let ioKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY)
  private let coreDisplay = dlopen(
    "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY)
  private lazy var getBrightness: GetBrightness? = symbol(
    displayServices, "DisplayServicesGetBrightness")
  private lazy var setBrightness: SetBrightness? = symbol(
    displayServices, "DisplayServicesSetBrightness")
  private lazy var createService: CreateService? = symbol(ioKit, "IOAVServiceCreateWithService")
  private lazy var readI2C: Transfer? = symbol(ioKit, "IOAVServiceReadI2C")
  private lazy var writeI2C: Transfer? = symbol(ioKit, "IOAVServiceWriteI2C")
  private lazy var displayInfo: DisplayInfo? = symbol(
    coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary")

  private func symbol<T>(_ handle: UnsafeMutableRawPointer?, _ name: String) -> T? {
    guard let handle, let address = dlsym(handle, name) else { return nil }
    return unsafeBitCast(address, to: T.self)
  }

  func readBuiltIn(_ id: CGDirectDisplayID) -> Double? {
    guard let getBrightness, setBrightness != nil else { return nil }
    var value: Float = 0
    guard getBrightness(id, &value) == 0, value.isFinite else { return nil }
    return Double(max(0, min(1, value))) * 100
  }

  func writeBuiltIn(_ id: CGDirectDisplayID, percent: Double) -> Bool {
    setBrightness?(id, Float(percent / 100)) == 0
  }

  private struct Candidate {
    let service: CFTypeRef
    let location: String
    let registryID: UInt64
    let product: NSDictionary
    let edid: String
  }

  /// Same framebuffer/proxy traversal as MonitorControl, with explicit IOObject
  /// ownership. Exact location wins; otherwise require unique identity matches.
  /// Never fall back to enumeration order for indistinguishable monitors.
  func services(for ids: [CGDirectDisplayID]) -> [CGDirectDisplayID: CFTypeRef] {
    #if arch(arm64)
      guard let createService, readI2C != nil, writeI2C != nil else { return [:] }
      let root = IORegistryGetRootEntry(kIOMainPortDefault)
      defer { IOObjectRelease(root) }
      var iterator: io_iterator_t = 0
      guard
        IORegistryEntryCreateIterator(
          root, kIOServicePlane,
          IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS
      else { return [:] }
      defer { IOObjectRelease(iterator) }
      var candidates: [Candidate] = []
      var location = ""
      var product = NSDictionary()
      var edid = ""
      while case let entry = IOIteratorNext(iterator), entry != 0 {
        defer { IOObjectRelease(entry) }
        var name = [CChar](repeating: 0, count: 128)
        guard IORegistryEntryGetName(entry, &name) == KERN_SUCCESS else { continue }
        let entryName = String(cString: name)
        if entryName.contains("AppleCLCD2") || entryName.contains("IOMobileFramebufferShim") {
          var path = [CChar](repeating: 0, count: 512)
          location =
            IORegistryEntryGetPath(entry, kIOServicePlane, &path) == KERN_SUCCESS
            ? String(cString: path) : ""
          let attributes = property(entry, "DisplayAttributes") as? NSDictionary
          product = attributes?["ProductAttributes"] as? NSDictionary ?? NSDictionary()
          edid = property(entry, "EDID UUID") as? String ?? ""
        } else if entryName == "DCPAVServiceProxy",
          property(entry, "Location") as? String == "External",
          let service = createService(kCFAllocatorDefault, entry)?.takeRetainedValue()
        {
          var registryID: UInt64 = 0
          IORegistryEntryGetRegistryEntryID(entry, &registryID)
          candidates.append(
            Candidate(
              service: service, location: location, registryID: registryID, product: product,
              edid: edid))
        }
      }
      var proposals: [CGDirectDisplayID: Int] = [:]
      for id in ids {
        let info = displayInfo?(id)?.takeRetainedValue() as NSDictionary?
        let scores = candidates.map { candidate -> Int in
          if let loc = info?["IODisplayLocation"] as? String, !loc.isEmpty,
            loc == candidate.location
          {
            return 100
          }
          let vendor = CGDisplayVendorNumber(id)
          let model = CGDisplayModelNumber(id)
          let prefix = String(format: "%04X%02X%02X", vendor, model & 255, (model >> 8) & 255)
          let identityMatches =
            (candidate.product["LegacyManufacturerID"] as? NSNumber)?.uint32Value == vendor
            && (candidate.product["ProductID"] as? NSNumber)?.uint32Value == model
          guard identityMatches || candidate.edid.hasPrefix(prefix) else { return 0 }
          let serial = CGDisplaySerialNumber(id)
          let names = info?["DisplayProductName"] as? [String: String]
          let name = names?["en_US"] ?? names?.values.first ?? ""
          let nameMatches =
            !name.isEmpty
            && name.lowercased() == (candidate.product["ProductName"] as? String)?.lowercased()
          return 10 + (nameMatches ? 2 : 0)
            + (serial != 0
              && (candidate.product["SerialNumber"] as? NSNumber)?.uint32Value == serial ? 5 : 0)
        }
        guard let best = scores.max(), best > 0,
          scores.filter({ $0 == best }).count == 1, let index = scores.firstIndex(of: best)
        else { continue }
        proposals[id] = index
      }
      var result: [CGDirectDisplayID: CFTypeRef] = [:]
      for (id, index) in proposals where proposals.values.filter({ $0 == index }).count == 1 {
        result[id] = candidates[index].service
        os_log(
          "Brightness match: display=%u DCPAVServiceProxy=%llu framebuffer=%{public}@ EDID=%{public}@ product=%{public}@",
          id, candidates[index].registryID, candidates[index].location, candidates[index].edid,
          candidates[index].product.description)
      }
      return result
    #else
      return [:]
    #endif
  }

  private func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
    IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
      .takeRetainedValue()
  }

  func readDDC(_ service: CFTypeRef) -> (current: UInt16, maximum: UInt16)? {
    guard let writeI2C, let readI2C else { return nil }
    for attempt in 0..<5 {
      // Standard DDC includes source address 0x51. Samsung rejects the legacy
      // MonitorControl checksum with a valid null response; retry legacy only
      // for bridges which require it. Never accept null or corrupt replies.
      var request: [UInt8] = [0x82, 0x01, 0x10, 0x6E ^ 0x82 ^ 0x01 ^ 0x10]
      if attempt < 3 { request[3] ^= 0x51 }
      // Two write cycles, paced at 10ms, as in MonitorControl.
      var sent = false
      for _ in 0..<2 {
        usleep(10_000)
        sent = request.withUnsafeMutableBytes {
          writeI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) == 0
        }
      }
      usleep(50_000)
      var reply = [UInt8](repeating: 0, count: 11)
      let received =
        sent
        && reply.withUnsafeMutableBytes {
          readI2C(service, 0x37, 0, $0.baseAddress!, UInt32($0.count)) == 0
        }
      if received, reply[0] == 0x6E, reply[1] == 0x88, reply[2] == 0x02,
        reply[3] == 0, reply[4] == 0x10,
        reply.dropLast().reduce(UInt8(0x50), ^) == reply.last!
      {
        let maximum = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        if maximum > 0, current <= maximum { return (current, maximum) }
      }
      if ProcessInfo.processInfo.environment["MS_DDC_DEBUG"] != nil {
        print("DDC reply attempt=\(attempt) sent=\(sent) received=\(received) bytes=\(reply)")
      }
      if attempt < 4 { usleep(20_000) }
    }
    return nil
  }

  func writeDDC(_ service: CFTypeRef, value: UInt16) -> Bool {
    guard let writeI2C else { return false }
    var packet: [UInt8] = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 255)]
    packet.append(packet.reduce(UInt8(0x6E ^ 0x51), ^))
    for _ in 0..<5 {
      var success = false
      for _ in 0..<2 {
        usleep(10_000)
        success = packet.withUnsafeMutableBytes {
          writeI2C(service, 0x37, 0x51, $0.baseAddress!, UInt32($0.count)) == 0
        }
      }
      if success { return true }
      usleep(20_000)
    }
    return false
  }
}
