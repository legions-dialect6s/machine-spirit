import AppKit
import CoreAudio

private func audioUInt(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> UInt32 {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout.size(ofValue: value))
    let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
    guard status == noErr else { throw Failure("CoreAudio property unavailable (\(status))") }
    return value
}

/// Public AppKit bundle/name information resolves common audio helpers. Unknown
/// helpers retain their own PID; never attribute them to an arbitrary browser.
@MainActor
func audioOwner(_ process: NSRunningApplication?, regular: [NSRunningApplication]) -> NSRunningApplication? {
    guard let process else { return nil }
    if process.activationPolicy == .regular { return process }
    if let path = process.bundleURL?.standardizedFileURL.path {
        let matches = regular.filter { app in
            guard let root = app.bundleURL?.standardizedFileURL.path else { return false }
            return path.hasPrefix(root + "/")
        }
        if matches.count == 1 { return matches[0] }
    }
    // WebKit XPC services live outside Safari.app, but AppKit assigns their
    // hosting application's display name (e.g. Safari Graphics and Media).
    if process.bundleIdentifier?.hasPrefix("com.apple.WebKit.") == true, let name = process.localizedName {
        let matches = regular.filter { app in
            guard let owner = app.localizedName else { return false }
            return name == owner + " Graphics and Media" || name == owner + " Web Content" || name == owner + " Networking"
        }
        if matches.count == 1 { return matches[0] }
    }
    return process
}

@MainActor
func audio(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args)
    guard parsed.positionals.count <= 1, ["list", "tile"].contains(parsed.positionals.first ?? "list") else {
        throw Failure("usage: ms audio [list|tile]")
    }
    guard #available(macOS 14.4, *) else { throw Failure("audio requires macOS 14.4 or newer") }
    var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
        throw Failure("cannot enumerate CoreAudio processes")
    }
    var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    if size > 0 {
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { throw Failure("CoreAudio process list changed; retry (\(status))") }
    }
    var pids = Set<pid_t>()
    var rows: [[String: Any]] = []
    let regular = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
    for object in objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size) {
        // Processes can exit between list and property reads.
        guard (try? audioUInt(object, kAudioProcessPropertyIsRunningOutput)) == 1,
              let raw = try? audioUInt(object, kAudioProcessPropertyPID) else { continue }
        let pid = pid_t(bitPattern: raw)
        let producer = NSRunningApplication(processIdentifier: pid)
        let app = audioOwner(producer, regular: regular)
        let ownerPID = app?.processIdentifier ?? pid
        if let index = rows.firstIndex(where: { $0["pid"] as? Int32 == ownerPID }) {
            rows[index]["audioProcessPIDs"] = (rows[index]["audioProcessPIDs"] as! [Int32]) + [pid]
            continue
        }
        pids.insert(ownerPID)
        rows.append(["pid": ownerPID, "name": app?.localizedName ?? "Process \(pid)",
                     "bundleId": app?.bundleIdentifier as Any? ?? NSNull(), "audioProcessPIDs": [pid],
                     "attribution": ownerPID == pid ? "process" : "AppKit helper ownership (bundle path or WebKit display name)"])
    }
    rows.sort { ($0["pid"] as! Int32) < ($1["pid"] as! Int32) }
    if parsed.positionals.first == "tile" {
        guard !pids.isEmpty else { throw Failure("no apps are producing audio", exitCode: 11) }
        guard AXIsProcessTrusted() else { throw Failure("Accessibility not granted to the calling process") }
        return try tileAllWindows(onlyPIDs: pids, underMouse: true)
    }
    let note = "App/process-level active output streams only; browser per-tab audio and audible signal levels are not exposed."
    return Output(json: ["apps": rows, "notes": [note]],
                  text: rows.isEmpty ? "No apps are producing audio." : rows.map { "\($0["pid"]!) \($0["name"]!) (\($0["bundleId"]!))" }.joined(separator: "\n"))
}
