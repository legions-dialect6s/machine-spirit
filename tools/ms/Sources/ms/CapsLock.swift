import CoreGraphics
import Foundation
import IOKit.hidsystem

func showHUD(_ items: [URLQueryItem]) {
    var url = URLComponents()
    url.scheme = "machinespirit"
    url.host = "hud"
    url.queryItems = items
    if let value = url.url?.absoluteString { _ = try? process("/usr/bin/open", ["-g", value], detached: true) }
}

func capslock(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args)
    guard parsed.positionals.count <= 1 else { throw Failure("usage: ms capslock [on|off|toggle|status]") }
    let action = parsed.positionals.first ?? "status"
    guard ["on", "off", "toggle", "status"].contains(action) else { throw Failure("unknown capslock action: \(action)") }
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
    guard service != 0 else { throw Failure("IOHIDSystem is unavailable") }
    defer { IOObjectRelease(service) }
    var connection: io_connect_t = 0
    let opened = IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connection)
    guard opened == KERN_SUCCESS else { throw Failure("cannot open IOHIDSystem (\(opened))") }
    defer { IOServiceClose(connection) }
    var locked = false
    guard IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &locked) == KERN_SUCCESS else {
        throw Failure("cannot read Caps Lock state")
    }
    // What apps type with is the event system's Caps Lock flag. The IOHIDSystem lock
    // state can go stale (seen 2026-11-28: lock "on", flag and keyboards off), and then
    // setting the value it already reports is a no-op, so every toggle failed silently.
    var state = CGEventSource.flagsState(.hidSystemState).contains(.maskAlphaShift)
    if action != "status" {
        let requested = action == "toggle" ? !state : action == "on"
        func set(_ value: Bool) -> Bool {
            IOHIDSetModifierLockState(connection, Int32(kIOHIDCapsLockState), value) == KERN_SUCCESS
        }
        // Flip through the opposite value when the stale lock already reads `requested`.
        if locked == requested { _ = set(!requested) }
        guard set(requested),
              IOHIDGetModifierLockState(connection, Int32(kIOHIDCapsLockState), &state) == KERN_SUCCESS,
              state == requested else { throw Failure("cannot set or verify Caps Lock state") }
        showHUD([URLQueryItem(name: "style", value: "caps"), URLQueryItem(name: "state", value: state ? "on" : "off")])
    }
    return Output(json: ["state": state ? "on" : "off"], text: state ? "on" : "off")
}
