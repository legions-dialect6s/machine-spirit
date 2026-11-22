import Foundation
import Darwin

/// Filesystem metadata only. Keep the cost independent of the number of crash reports.
struct PulseDiskReview {
    static let gibibyte: UInt64 = 1 << 30
    let freeBytes: UInt64?
    let capacityBytes: UInt64?
    let pendingEntries: Int?
    var externalVolumes: [PulseVolumeReading] = []
    var volumeReadError: String? = nil
    var projectTarget: PulseVolumeTarget? = nil

    static var crashQueue: URL { homeURL("Library/Application Support/Codex/Crashpad/pending") }

    static func read(checkQueue: Bool, refreshVolumes: Bool = false) -> Self {
        var disk = statfs()
        let available = statfs("/System/Volumes/Data", &disk) == 0 && disk.f_bsize > 0
        var review = Self(freeBytes: available ? disk.f_bavail * UInt64(disk.f_bsize) : nil,
                    capacityBytes: available ? disk.f_blocks * UInt64(disk.f_bsize) : nil,
                    pendingEntries: checkQueue ? queueEntryCount(at: crashQueue) : nil)
        do {
            let config = pulseDirectory.appendingPathComponent("volumes.json")
            let targets = try PulseVolumeTarget.configured(at: config)
            review.projectTarget = targets.first { $0.projectProvider != nil }
            review.externalVolumes = PulseVolumeReading.read(targets, refresh: refreshVolumes)
        } catch {
            review.volumeReadError = error.localizedDescription
        }
        return review
    }

    static func queueEntryCount(at directory: URL) -> Int? {
        // Foundation returns nil if the filesystem cannot cheaply supply a count.
        let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .directoryEntryCountKey])
        guard values?.isDirectory == true, values?.isSymbolicLink == false else { return nil }
        return values?.directoryEntryCount
    }

    var reserveBytes: UInt64? { capacityBytes.map { min($0 / 10, 30 * Self.gibibyte) } }

    static func gib(_ bytes: UInt64) -> String {
        String(format: "%.1f GiB", Double(bytes) / Double(gibibyte))
    }

    var suggestions: [String] {
        var result: [String] = []
        if let freeBytes, let reserveBytes, freeBytes < reserveBytes {
            result.append("Startup disk has \(Self.gib(freeBytes)) free. Review completed exports or regenerable files to regain the \(Self.gib(reserveBytes)) reserve.")
        }
        if let pendingEntries, pendingEntries >= 1_000 {
            result.append("Codex has \(pendingEntries) entries in its pending crash queue, including metadata. Run ms pulse disk --crash-preview to check their ages and sizes.")
        }
        for volume in externalVolumes {
            if let free = volume.freeBytes, let threshold = volume.reviewThresholdBytes, free < threshold {
                result.append("\(volume.name) is below its 10% review threshold. Review recent exports or installs.")
            }
        }
        return result
    }

    var output: Output {
        let free = freeBytes.map(Self.gib) ?? "unavailable"
        let reserve = reserveBytes.map(Self.gib) ?? "unavailable"
        let count = pendingEntries.map(String.init) ?? "unavailable"
        var lines = ["Startup disk free: \(free)", "Review reserve: \(reserve)",
                     "Codex pending crash queue entries: \(count)"]
        for volume in externalVolumes {
            if let free = volume.freeBytes, let threshold = volume.reviewThresholdBytes {
                lines.append("\(volume.name): \(Self.gib(free)) free (10% review threshold: \(Self.gib(threshold)))")
            } else {
                lines.append("\(volume.name): \(volume.status.rawValue)")
            }
        }
        if let volumeReadError { lines.append(volumeReadError) }
        lines += suggestions
        return Output(json: json, text: lines.joined(separator: "\n"))
    }

    var json: [String: Any] {
        ["freeDiskBytes": freeBytes as Any? ?? NSNull(),
         "reserveBytes": reserveBytes as Any? ?? NSNull(),
         "externalVolumes": externalVolumes.map(\.json),
         "externalVolumeError": volumeReadError as Any? ?? NSNull(),
         "codexPendingEntries": pendingEntries as Any? ?? NSNull(),
         "suggestions": suggestions]
    }
}
