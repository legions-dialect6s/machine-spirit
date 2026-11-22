import Darwin
import Foundation

/// Only the interactive disk command constructs this reading.
@MainActor
struct PulseProjectReading {
    let disk: PulseDiskReview
    let preview: ProjectDiskPreview

    init() {
        disk = PulseDiskReview.read(checkQueue: true, refreshVolumes: true)
        if let target = disk.projectTarget, let provider = target.projectProvider {
            preview = ProjectDiskPreview.read(directory: pulseDirectory, provider: provider, expectedVolume: target.volumeUUID, volumes: disk.externalVolumes)
        } else {
            preview = .unavailable(reason: "No project preview provider is configured.")
        }
    }

    var output: Output {
        var json = disk.json
        json["projectPreview"] = preview.json
        return Output(json: json, text: disk.output.text + "\n" + preview.summary)
    }

    func explained() async -> Output {
        let baseline = PulseDiskBaseline.latest(in: pulseDirectory)
        let project = disk.externalVolumes.first { $0.volumeUUID == disk.projectTarget?.volumeUUID && $0.status == .mounted }
        let prior = baseline?.externalVolumes?.first { $0.volumeUUID == project?.volumeUUID && $0.status == .mounted }
        let startupDelta = PulseDiskBaseline.delta(from: baseline?.freeDiskBytes, to: disk.freeBytes)
        let projectDelta = PulseDiskBaseline.delta(from: prior?.freeBytes, to: project?.freeBytes)
        let facts = PulseDiskExplanation.Input(
            startupFreeBytes: disk.freeBytes, startupReserveBytes: disk.reserveBytes, startupDeltaBytes: startupDelta,
            projectFreeBytes: project?.freeBytes, projectThresholdBytes: project?.reviewThresholdBytes,
            projectDeltaBytes: projectDelta, previewStatus: preview.status, reclaimableBytes: preview.reclaimableBytes,
            previewCategoryCount: (preview.json["categories"] as? [[String: Any]])?.count)
        let explanation = await PulseDiskExplanation.explain(facts)
        var json = disk.json
        json["projectPreview"] = preview.json
        json["diskChanges"] = ["since": baseline?.timestamp as Any? ?? NSNull(),
                               "startupFreeBytesChange": startupDelta as Any? ?? NSNull(),
                               "projectFreeBytesChange": projectDelta as Any? ?? NSNull()]
        json["explanation"] = explanation.json
        var lines = [output.text]
        if let baseline, startupDelta != nil || projectDelta != nil {
            lines.append("Changes since the hourly sample at \(baseline.timestamp).")
        }
        lines.append("\(explanation.text) [\(explanation.source): \(explanation.reason)]")
        return Output(json: json, text: lines.joined(separator: "\n"))
    }
}

/// Decode only disk measurements from the most recent complete hourly sample.
/// Cap IO and allocations even if the collector has written an unusually large month.
struct PulseDiskBaseline: Decodable {
    let timestamp: String
    let freeDiskBytes: UInt64?
    let externalVolumes: [PulseVolumeReading]?

    static func delta(from prior: UInt64?, to current: UInt64?) -> Int64? {
        guard let prior, let current, let start = Int64(exactly: prior), let end = Int64(exactly: current) else { return nil }
        return end - start
    }

    static func latest(in directory: URL, now: Date = Date()) -> Self? {
        let earliest = now.addingTimeInterval(-86_400)
        let months = Set([now, earliest].map { String($0.ISO8601Format().prefix(7)) }).sorted(by: >)
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        for month in months {
            let url = directory.appendingPathComponent(month + ".jsonl")
            guard let data = recentLines(at: url) else { continue }
            // appendPulse commits a row by writing its terminating newline.
            let lines = data.split(separator: 10, omittingEmptySubsequences: false).dropLast()
            for line in lines.reversed() {
                guard let row = try? decoder.decode(Self.self, from: line),
                      let date = formatter.date(from: row.timestamp), date < now, date >= earliest else { continue }
                return row
            }
        }
        return nil
    }

    private static func recentLines(at url: URL) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW_ANY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o022 == 0, info.st_size > 0 else { return nil }
        let length = Int(min(info.st_size, 256 * 1024))
        let offset = info.st_size - Int64(length)
        var data = Data(count: length)
        let count = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress!, length, offset) }
        guard count == length else { return nil }
        if offset > 0 {
            guard let newline = data.firstIndex(of: 10) else { return nil }
            data.removeSubrange(...newline)
        }
        return data
    }
}
