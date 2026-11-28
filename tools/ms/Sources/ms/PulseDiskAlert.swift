import Darwin
import Foundation

/// Low-disk notifications for `ms pulse collect --alert`. The decision is a pure function of the
/// fresh readings and the previous state; delivery and the state file are separate, so a failed
/// notification is retried by the next hourly sample instead of being recorded as sent.
struct PulseDiskAlert {
    enum Level: String, Codable { case ok, low }

    struct Entry: Codable, Equatable {
        var level: Level
        var lastNotifiedAt: Date? = nil
        var lastNotifiedFreeBytes: UInt64? = nil
    }

    struct State: Codable, Equatable { var targets: [String: Entry] = [:] }

    /// One watched disk. `freeBytes` is nil when the disk could not be measured in this sample:
    /// unmounted, replaced by another volume or unreadable. An unmeasured disk is never "recovered".
    struct Reading {
        let key: String
        let name: String
        let freeBytes: UInt64?
        let floorBytes: UInt64?
    }

    struct Notice: Equatable {
        let key: String
        let title: String
        let body: String
    }

    /// Remind once a day while a disk stays under its floor.
    static let reminderInterval: TimeInterval = 24 * 3600
    static let stateFileName = "disk-alerts.json"

    /// A disk leaves "low" only once it is 10% above its floor, so a disk hovering at the floor
    /// does not alternate between low and recovered every hour.
    static func recoveryBytes(_ floor: UInt64) -> UInt64 { floor + floor / 10 }

    /// External drives: 5% of capacity, capped at 50 GiB. A `volumes.json` entry can set its own
    /// `alertFloorGiB`; zero switches alerts off for that drive.
    static func defaultFloor(capacityBytes: UInt64) -> UInt64 { min(capacityBytes / 20, 50 * PulseDiskReview.gibibyte) }

    static func readings(_ review: PulseDiskReview) -> [Reading] {
        [Reading(key: "startup", name: "Startup disk", freeBytes: review.freeBytes, floorBytes: review.reserveBytes)] +
            review.externalVolumes.map {
                Reading(key: $0.volumeUUID.uuidString, name: $0.name,
                        freeBytes: $0.status == .mounted ? $0.freeBytes : nil, floorBytes: $0.alertFloorBytes)
            }
    }

    static func evaluate(_ readings: [Reading], previous: State, now: Date) -> (notices: [Notice], state: State) {
        var notices: [Notice] = [], next = State()
        for reading in readings {
            let before = previous.targets[reading.key]
            guard let floor = reading.floorBytes, floor > 0 else { continue }
            // Unmeasured: carry the last known level forward untouched and say nothing.
            guard let free = reading.freeBytes else {
                next.targets[reading.key] = before
                continue
            }
            let floorText = PulseDiskReview.gib(floor), freeText = PulseDiskReview.gib(free)
            if free < floor {
                var entry = before?.level == .low ? before! : Entry(level: .low)
                let reminderDue = entry.lastNotifiedAt.map { now.timeIntervalSince($0) >= reminderInterval } ?? true
                let halved = entry.lastNotifiedFreeBytes.map { $0 > 0 && free <= $0 / 2 } ?? false
                if before?.level != .low || reminderDue || halved {
                    notices.append(Notice(key: reading.key, title: "Low disk space",
                                          body: "\(reading.name): \(freeText) free, below its \(floorText) floor."))
                    entry.lastNotifiedAt = now
                    entry.lastNotifiedFreeBytes = free
                }
                next.targets[reading.key] = entry
            } else if before?.level == .low, free < recoveryBytes(floor) {
                next.targets[reading.key] = before
            } else {
                if before?.level == .low {
                    notices.append(Notice(key: reading.key, title: "Disk space recovered",
                                          body: "\(reading.name): \(freeText) free, back above its \(floorText) floor."))
                }
                next.targets[reading.key] = Entry(level: .ok)
            }
        }
        return (notices, next)
    }

    static func load(from directory: URL) -> State {
        let file = directory.appendingPathComponent(stateFileName)
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return State() }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), info.st_size <= 65536,
              let data = try? handle.read(upToCount: 65536) else { return State() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(State.self, from: data)) ?? State()
    }

    static func save(_ state: State, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(state); data.append(10)
        let file = directory.appendingPathComponent(stateFileName)
        let temporary = directory.appendingPathComponent(".\(stateFileName).\(getpid()).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]),
              rename(temporary.path, file.path) == 0 else {
            unlink(temporary.path)
            throw Failure("cannot write Pulse \(stateFileName)")
        }
    }

    /// Literal argv, never interpolated into the script. A banner needs no Automation consent.
    /// The helper gets 15 seconds: started by a background LaunchAgent on a busy Mac, `osascript`
    /// alone was measured at 5.2 seconds, and the sample is already stored by the time this runs.
    static let deliveryDeadline: TimeInterval = 15

    static func post(_ notice: Notice) -> Bool {
        let child = PulseChild("/usr/bin/osascript", [
            "-e", "on run argv", "-e", "display notification (item 2 of argv) with title (item 1 of argv)",
            "-e", "end run", notice.title, notice.body,
        ])
        PulseChild.finish([child], deadline: ProcessInfo.processInfo.systemUptime + deliveryDeadline)
        return child.output != nil
    }

    /// Evaluate, deliver and persist. A notice that could not be delivered keeps its disk's
    /// previous entry, so the same transition is evaluated again on the next sample.
    static func run(_ review: PulseDiskReview, directory: URL, now: Date = Date(),
                    deliver: (Notice) -> Bool = PulseDiskAlert.post) -> [String: Any] {
        let previous = load(from: directory)
        let evaluated = evaluate(readings(review), previous: previous, now: now)
        var state = evaluated.state
        var posted: [Notice] = [], failed: [Notice] = []
        for notice in evaluated.notices {
            if deliver(notice) { posted.append(notice) } else {
                failed.append(notice)
                state.targets[notice.key] = previous.targets[notice.key]
            }
        }
        var result: [String: Any] = [
            "posted": posted.map { ["title": $0.title, "body": $0.body] },
            "failed": failed.map { ["title": $0.title, "body": $0.body] },
            "low": state.targets.filter { $0.value.level == .low }.keys.sorted(),
        ]
        if state != previous {
            do { try save(state, to: directory) } catch { result["stateError"] = error.localizedDescription }
        }
        return result
    }
}
