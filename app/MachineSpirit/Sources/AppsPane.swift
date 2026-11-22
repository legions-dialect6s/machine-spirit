import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct TorStatus: Decodable {
  let mode: String
  let hasWireguard: Bool
  let endpoint: String?
  let applianceReady: Bool
}

struct AppsPane: View {
  private let helper = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("bin/tor-session.py")

  @State private var mode = "tor-only"
  @State private var hasWireguard = false
  @State private var endpoint: String? = nil
  @State private var applianceReady = false
  @State private var message = ""
  @State private var isError = false
  @State private var activeTask: Process?
  @State private var requestID = 0

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 14) {
        HStack {
          Label("Tor Browser", systemImage: "network.badge.shield.half.filled")
            .font(.title2.bold())
            .foregroundStyle(Theme.phosphor)
          Spacer()
          Text("T-O-R")
            .font(.system(.caption, design: .monospaced).bold())
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.phosphor.opacity(0.15))
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(Theme.phosphor)
        }

        Text("Runs directly in a read-only, RAM-only ARM64 Linux kiosk VM. No desktop chrome, no host files, no clipboard bridge. Closing the window wipes the entire session.")
          .font(.callout)
          .foregroundStyle(.secondary)

        Picker(
          "In-VM Network",
          selection: Binding(
            get: { mode },
            set: { newMode in setMode(newMode) }
          )
        ) {
          Text("Tor Only (DNS/IPv6 firewall inside VM)").tag("tor-only")
          Text("WireGuard VPN + Killswitch (inside VM)").tag("wireguard")
        }
        .pickerStyle(.radioGroup)

        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 8) {
            if hasWireguard, let ep = endpoint {
              Label("WireGuard config ready (\(ep))", systemImage: "checkmark.shield.fill")
                .font(.caption)
                .foregroundStyle(Theme.phosphor)
            } else {
              Label("No WireGuard .conf imported yet", systemImage: "shield.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
            }
          }

          HStack(spacing: 8) {
            Button("Import WireGuard .conf…") { importWireguard() }
            Button("Get Free Proton .conf") {
              NSWorkspace.shared.open(
                URL(string: "https://account.protonvpn.com/downloads#wireguard-configuration")!
              )
            }
            if hasWireguard {
              Button("Remove") { removeWireguard() }
            }
          }

          Text("Proton Free gives standard Linux WireGuard .conf files on their website — no Proton Mac app or ads needed. Your Mac's own Wi-Fi and VPN settings are never touched.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(Color.primary.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))

        HStack(spacing: 12) {
          Button("Open Tor Browser") { launch() }
            .buttonStyle(.borderedProminent)
            .disabled(mode == "wireguard" && !hasWireguard)

          if !applianceReady {
            Text("First launch builds the ~450 MB Linux appliance once.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        if !message.isEmpty {
          Text(message)
            .font(.callout)
            .foregroundStyle(isError ? Color.red : Theme.phosphor)
        }
      }
      .frame(maxWidth: 540, alignment: .leading)
      .padding(24)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(maxHeight: .infinity)
    .onAppear { refresh() }
    .onDisappear {
      requestID += 1
      if let proc = activeTask, proc.isRunning { proc.terminate() }
      activeTask = nil
    }
  }

  private func runHelper(_ args: [String], onSuccess: @escaping @MainActor @Sendable (Data) -> Void) {
    requestID += 1
    let token = requestID
    if let prev = activeTask, prev.isRunning { prev.terminate() }

    let task = Process()
    let out = Pipe()
    let err = Pipe()
    task.executableURL = helper
    task.arguments = args
    task.standardOutput = out
    task.standardError = err
    activeTask = task

    final class PipeBuffer: @unchecked Sendable {
      private let lock = NSLock()
      private var data = Data()
      private let limit: Int
      init(limit: Int = 65_536) { self.limit = limit }
      func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        let remaining = limit - data.count
        if remaining > 0 { data.append(chunk.prefix(remaining)) }
        lock.unlock()
      }
      func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
      }
    }

    let outBuf = PipeBuffer()
    let errBuf = PipeBuffer()
    let outHandle = out.fileHandleForReading
    let errHandle = err.fileHandleForReading
    outHandle.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty { handle.readabilityHandler = nil } else { outBuf.append(chunk) }
    }
    errHandle.readabilityHandler = { handle in
      let chunk = handle.availableData
      if chunk.isEmpty { handle.readabilityHandler = nil } else { errBuf.append(chunk) }
    }

    task.terminationHandler = { proc in
      outHandle.readabilityHandler = nil
      errHandle.readabilityHandler = nil
      outBuf.append(outHandle.readDataToEndOfFile())
      errBuf.append(errHandle.readDataToEndOfFile())
      let outData = outBuf.snapshot()
      let errText = String(data: errBuf.snapshot(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let status = proc.terminationStatus
      Task { @MainActor in
        guard token == requestID else { return }
        if activeTask === proc { activeTask = nil }
        if status == 0 {
          isError = false
          onSuccess(outData)
        } else {
          isError = true
          message = errText.isEmpty ? "Helper command failed." : errText
        }
      }
    }
    do {
      try task.run()
    } catch {
      outHandle.readabilityHandler = nil
      errHandle.readabilityHandler = nil
      activeTask = nil
      isError = true
      message = error.localizedDescription
    }
  }

  private func applyStatusData(_ data: Data) {
    guard let status = try? JSONDecoder().decode(TorStatus.self, from: data) else {
      isError = true
      message = "Could not read Tor status."
      return
    }
    mode = status.mode
    hasWireguard = status.hasWireguard
    endpoint = status.endpoint
    applianceReady = status.applianceReady
  }

  private func refresh() {
    runHelper(["--status"]) { data in
      applyStatusData(data)
    }
  }

  private func setMode(_ newMode: String) {
    if newMode == "wireguard" && !hasWireguard {
      mode = "wireguard"
      isError = false
      message = "Import a WireGuard .conf file below to enable the in-VM VPN killswitch."
      return
    }
    runHelper(["--set-mode", newMode]) { data in
      applyStatusData(data)
      message = ""
    }
  }

  private func importWireguard() {
    let panel = NSOpenPanel()
    panel.title = "Select WireGuard Configuration (.conf)"
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false
    panel.allowedContentTypes = [UTType(filenameExtension: "conf") ?? .plainText, .plainText]
    if panel.runModal() == .OK, let url = panel.url {
      runHelper(["--import-wg", url.path]) { _ in
        message = "WireGuard .conf imported (stored 0600, used only inside the VM)."
        refresh()
      }
    }
  }

  private func removeWireguard() {
    runHelper(["--remove-wg"]) { _ in
      message = "WireGuard .conf removed; switched to Tor Only mode."
      refresh()
    }
  }

  private func launch() {
    message = "Opening Tor Browser…"
    isError = false
    let task = Process()
    task.executableURL = helper
    task.terminationHandler = { _ in
      DispatchQueue.main.async { message = "" }
    }
    do {
      try task.run()
    } catch {
      isError = true
      message = error.localizedDescription
    }
  }
}
