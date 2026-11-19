// swift tools/ObserveLeaderIPC.swift [seconds]
// Leave this running while showing/navigating/hiding the panel or firing a bind.
import Foundation

let center = DistributedNotificationCenter.default()
let observers = ["com.machinespirit.leader.nav", "com.machinespirit.leader.fired"].map { name in
  center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { note in
    guard note.name.rawValue.hasPrefix("com.machinespirit.leader.") else { return }
    let payload = note.userInfo ?? [:]
    precondition(payload.values.allSatisfy { $0 is String }, "IPC values must all be strings")
    print("\(note.name.rawValue) \(payload)")
    fflush(stdout)
  }
}
print("Observing Leader Key IPC")
fflush(stdout)
RunLoop.main.run(
  until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "30") ?? 30))
observers.forEach { center.removeObserver($0) }
