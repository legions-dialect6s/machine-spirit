import Cocoa
import Darwin

// Read-only tmux protocol v8 client. Reference: tmux 3.7b tmux-protocol.h/client.c.
// Copyright (c) 2021 Nicholas Marriott <nicholas.marriott@gmail.com>
// Permission to use, copy, modify, and distribute this software for any
// purpose with or without fee is hereby granted, provided that the above
// copyright notice and this permission notice appear in all copies.
// THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
// WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
// MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
// ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
// WHATSOEVER RESULTING FROM LOSS OF MIND, USE, DATA OR PROFITS, WHETHER
// IN AN ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING
// OUT OF OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
// Does not attach, launch a server, send environment, or execute user commands.
enum TmuxReader {
  static func read(_ arguments: [String]) -> String? {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
    var noSigPipe: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, 4)
    let root = ProcessInfo.processInfo.environment["TMUX_TMPDIR"] ?? "/private/tmp"
    let path = "\(root)/tmux-\(getuid())/default"
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
    }
    let connected = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    guard connected == 0 else { return errno == ENOENT || errno == ECONNREFUSED ? "" : nil }
    func bytes<T>(_ value: T) -> Data {
      var v = value
      return withUnsafeBytes(of: &v) { Data($0) }
    }
    func send(_ type: UInt32, _ body: Data = Data()) -> Bool {
      var data = bytes(type)
      data.append(bytes(UInt32(16 + body.count)))
      data.append(bytes(UInt32(8)))
      data.append(bytes(UInt32(getpid())))
      data.append(body)
      return data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
          let n = Darwin.send(
            fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, 0)
          if n <= 0 { return false }
          offset += n
        }
        return true
      }
    }
    guard send(111, bytes(UInt64(0x10000))), send(101, Data("xterm-256color\0".utf8)),
      send(102, Data([0])), send(108, Data("/\0".utf8)),
      send(107, bytes(getpid())), send(106)
    else { return nil }
    var command = bytes(Int32(arguments.count))
    for argument in arguments { command.append(Data((argument + "\0").utf8)) }
    guard send(200, command) else { return nil }
    var incoming = Data()
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 16384)
    let deadline = ProcessInfo.processInfo.systemUptime + 0.5
    while ProcessInfo.processInfo.systemUptime < deadline {
      let size = recv(fd, &buffer, buffer.count, 0)
      guard size > 0 else { return nil }
      incoming.append(contentsOf: buffer.prefix(size))
      while incoming.count >= 16 {
        let type = incoming.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        let length = Int(
          incoming.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self) })
        guard (16...1_048_576).contains(length) else { return nil }
        guard incoming.count >= length else { break }
        let body = Data(incoming[16..<length])
        incoming = Data(incoming.dropFirst(length))
        switch type {
        case 12: return nil  // Version mismatch: keep cached data; never guess another ABI.
        case 303:
          guard body.count >= 12 else { return nil }
          var ready = Data(body.prefix(4))
          ready.append(bytes(Int32(0)))
          guard send(305, ready) else { return nil }
        case 304:
          guard body.count >= 4 else { return nil }
          output.append(body.dropFirst(4))
          guard output.count < 1_048_576 else { return nil }
        case 203:
          guard body.count >= 4, body.withUnsafeBytes({ $0.loadUnaligned(as: Int32.self) }) == 0
          else { return nil }
          return String(data: output, encoding: .utf8)
        default: break
        }
      }
    }
    return nil
  }
}

/// Native Apple Events; only the requested scalar property is returned, never terminal contents.
enum TerminalReader {
  struct Terminal {
    let id: String
    let tty: String
    let name: String
  }
  private static func code(_ value: String) -> UInt32 {
    value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
  }
  private static func object(
    _ desired: String, container: NSAppleEventDescriptor,
    property: String? = nil
  ) -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(NSAppleEventDescriptor(typeCode: code(desired)), forKeyword: code("want"))
    record.setDescriptor(
      NSAppleEventDescriptor(enumCode: code(property == nil ? "indx" : "prop")),
      forKeyword: code("form"))
    record.setDescriptor(
      property.map { NSAppleEventDescriptor(typeCode: code($0)) }
        ?? NSAppleEventDescriptor(
          descriptorType: typeAbsoluteOrdinal, data: withUnsafeBytes(of: code("all ")) { Data($0) })!,
      forKeyword: code("seld"))
    record.setDescriptor(container, forKeyword: code("from"))
    return record.coerce(toDescriptorType: code("obj "))!
  }
  static func readITerm(pid: pid_t) -> [Terminal]? {
    let windows = object("cwin", container: NSAppleEventDescriptor.null())
    let tabs = object("Trmt", container: windows)
    let sessions = object("Trms", container: tabs)
    func property(_ name: String) -> [String]? {
      let event = NSAppleEventDescriptor(
        eventClass: code("core"), eventID: code("getd"),
        targetDescriptor: NSAppleEventDescriptor(processIdentifier: pid),
        returnID: AEReturnID(kAutoGenerateReturnID),
        transactionID: AETransactionID(kAnyTransactionID))
      event.setParam(
        object("prop", container: sessions, property: name), forKeyword: keyDirectObject)
      guard
        let reply = try? event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 0.6),
        reply.paramDescriptor(forKeyword: keyErrorNumber)?.int32Value ?? 0 == 0,
        let data = reply.paramDescriptor(forKeyword: keyDirectObject)
      else { return nil }
      func flatten(_ item: NSAppleEventDescriptor) -> [String] {
        if item.descriptorType == typeAEList {
          guard item.numberOfItems > 0 else { return [] }
          return (1...item.numberOfItems).flatMap { index in
            item.atIndex(index).map(flatten) ?? []
          }
        }
        return [item.stringValue ?? ""]
      }
      return flatten(data)
    }
    guard let ids = property("ID  "), let ttys = property("Stty"), let names = property("pnam"),
      ids.count == ttys.count, ids.count == names.count
    else { return nil }
    return ids.indices.map { Terminal(id: ids[$0], tty: ttys[$0], name: names[$0]) }
  }
}

extension TerminalReader {
  /// Match terminals-core's non-iTerm login-shell discovery, without a ps subprocess.
  static func otherTerminals(excluding ttys: Set<String>) -> [Terminal] {
    let capacity = max(1024, Int(proc_listallpids(nil, 0)) + 128)
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride)))
    var result: [Terminal] = []
    var seen = Set<String>()
    for pid in pids.prefix(max(0, min(count, capacity))) where pid > 0 {
      var info = proc_bsdinfo()
      guard
        proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
          == MemoryLayout<proc_bsdinfo>.size,
        info.e_tdev != UInt32.max, info.e_tdev != 0
      else { continue }
      let name = withUnsafePointer(to: &info.pbi_comm) {
        $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXCOMLEN)) { String(cString: $0) }
      }
      guard ["zsh", "bash", "fish", "-zsh", "-bash", "-fish"].contains(name),
        let ttyName = devname(dev_t(bitPattern: info.e_tdev), mode_t(S_IFCHR))
      else { continue }
      let tty = "/dev/" + String(cString: ttyName)
      guard !ttys.contains(tty) else { continue }
      var ancestor = pid
      for _ in 0..<20 where ancestor > 1 {
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        if proc_pidpath(ancestor, &path, UInt32(path.count)) > 0 {
          let value = String(cString: path)
          if let range = value.range(of: ".app/Contents/MacOS/") {
            let app = URL(fileURLWithPath: String(value[..<range.lowerBound])).lastPathComponent
            if !app.hasPrefix("iTerm"), seen.insert(app).inserted {
              result.append(Terminal(id: "app:" + app, tty: tty, name: app))
            }
            break
          }
        }
        var parent = proc_bsdinfo()
        guard
          proc_pidinfo(
            ancestor, PROC_PIDTBSDINFO, 0, &parent, Int32(MemoryLayout<proc_bsdinfo>.size)) > 0
        else { break }
        ancestor = pid_t(parent.pbi_ppid)
      }
    }
    return result
  }
}
