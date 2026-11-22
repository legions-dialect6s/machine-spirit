import CoreFoundation
import Darwin
import Foundation

/// A point-in-time estimate supplied by the project. Reading it never invokes the producer.
struct ProjectDiskPreview {
    private let provider: String?

    static func validProvider(_ id: String) -> Bool {
        id.wholeMatch(of: /[a-z0-9_-]{1,64}/) != nil
    }
    private static let maxBytes = 64 * 1024

    let status: String
    let reclaimableBytes: UInt64?
    private let categories: [[String: Any]]
    private let volumeUUID: UUID?
    private let generatedAt: String?
    private let reason: String?

    static func unavailable(reason: String) -> Self {
        Self(provider: nil, status: "unavailable", reclaimableBytes: nil, categories: [], volumeUUID: nil,
             generatedAt: nil, reason: reason)
    }

    var json: [String: Any] {
        var result: [String: Any] = ["schemaVersion": 1, "status": status,
                                     "reclaimableBytes": reclaimableBytes as Any? ?? NSNull(), "categories": categories]
        if let provider { result["providerId"] = provider }
        if let volumeUUID { result["volumeUUID"] = volumeUUID.uuidString }
        if let generatedAt { result["generatedAt"] = generatedAt }
        if let reason { result["reason"] = reason }
        return result
    }

    var summary: String {
        if let reclaimableBytes {
            return "Project preview: \(reclaimableBytes) estimated reclaimable bytes across \(categories.count) categories."
        }
        return "Project preview: \(status). Reclaimable bytes unknown. \(reason ?? "")"
    }

    static func read(directory: URL, provider: String, expectedVolume: UUID, volumes: [PulseVolumeReading], now: Date = Date()) -> Self {
        do {
            guard validProvider(provider) else { throw Failure("Invalid project provider identifier.") }
            guard volumes.contains(where: { $0.volumeUUID == expectedVolume && $0.status == .mounted }) else {
                throw Failure("The enrolled project volume is not mounted with the expected UUID.")
            }
            let data = try snapshotData(in: directory.appendingPathComponent("project-previews"), provider: provider)
            return try validate(data, provider: provider, expectedVolume: expectedVolume, now: now)
        } catch {
            return Self(provider: provider, status: "unavailable", reclaimableBytes: nil, categories: [], volumeUUID: expectedVolume,
                        generatedAt: nil, reason: (error as? Failure)?.message ?? "Malformed project preview.")
        }
    }

    private static func snapshotData(in directory: URL, provider: String) throws -> Data {
        // Even an MS_PULSE_DIR override must name a real directory on internal Data.
        // O_NOFOLLOW_ANY covers every directory component; openat pins the leaf lookup.
        let parent = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard parent >= 0 else { throw Failure("The private preview directory is missing or inaccessible.") }
        defer { close(parent) }
        var info = stat()
        guard fstat(parent, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else {
            throw Failure("The preview directory must be owner-only (0700).")
        }
        var internalData = stat(), filesystem = statfs()
        guard stat("/System/Volumes/Data", &internalData) == 0, info.st_dev == internalData.st_dev,
              fstatfs(parent, &filesystem) == 0, filesystem.f_flags & UInt32(MNT_IGNORE_OWNERSHIP) == 0 else {
            throw Failure("The preview directory must be on the startup Data volume with ownership enabled.")
        }

        let fd = openat(parent, provider + ".json", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw Failure("The project snapshot is missing or inaccessible.") }
        defer { close(fd) }
        guard fstat(fd, &info) == 0, info.st_dev == internalData.st_dev, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o7777 == 0o600, info.st_nlink == 1 else {
            throw Failure("The snapshot must be an owner-only regular file (0600).")
        }
        guard (1...Int64(maxBytes)).contains(info.st_size) else {
            throw Failure("The snapshot is empty or exceeds 64 KiB.")
        }

        var data = Data(count: Int(info.st_size))
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = Darwin.read(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw Failure("The snapshot changed or could not be read.") }
                offset += count
            }
        }
        var final = stat()
        guard fstat(fd, &final) == 0, final.st_size == info.st_size, final.st_nlink == 1,
              final.st_ctimespec.tv_sec == info.st_ctimespec.tv_sec, final.st_ctimespec.tv_nsec == info.st_ctimespec.tv_nsec else {
            throw Failure("The snapshot changed during the read.")
        }
        return data
    }

    /// Reject JSON booleans, fractional numbers and overflows instead of coercing NSNumber values.
    private static func integer(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["d", "f"].contains(String(cString: number.objCType)) else { return nil }
        return UInt64(number.stringValue)
    }

    private static func field(_ value: Any?) -> String? {
        guard let text = value as? String, text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func utcDate(_ text: String) -> Date? {
        guard let match = text.wholeMatch(of: /([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2})(?:\.([0-9]{1,9}))?(?:Z|\+00:00)/) else { return nil }
        let whole = String(match.1) + "Z"
        let format = ISO8601DateFormatter()
        guard let base = format.date(from: whole), format.string(from: base) == whole else { return nil }
        let fraction = match.2.flatMap { Double("0." + $0) } ?? 0
        return base.addingTimeInterval(fraction)
    }

    private static func validate(_ data: Data, provider: String, expectedVolume: UUID, now: Date) throws -> Self {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              integer(object["schemaVersion"]) == 1, object["providerId"] as? String == provider else {
            throw Failure("Unexpected preview schema or provider.")
        }
        guard let id = object["volumeUUID"] as? String, UUID(uuidString: id) == expectedVolume else {
            throw Failure("The snapshot refers to a different volume.")
        }
        guard let timestamp = object["generatedAt"] as? String, let generated = utcDate(timestamp) else {
            throw Failure("The snapshot lacks a valid UTC timestamp.")
        }
        let age = now.timeIntervalSince(generated)
        guard age <= 900 else { throw Failure("The snapshot is older than 15 minutes.") }
        guard age >= -60 else { throw Failure("The snapshot is more than 60 seconds in the future.") }
        guard let status = object["status"] as? String, let rows = object["categories"] as? [[String: Any]] else {
            throw Failure("Invalid preview status or categories.")
        }

        if status == "blocked" || status == "unavailable" {
            guard object["reclaimableBytes"] is NSNull, rows.isEmpty, let reason = field(object["reason"]) else {
                throw Failure("An unavailable estimate requires a null total, empty categories and a reason.")
            }
            return Self(provider: provider, status: status, reclaimableBytes: nil, categories: [], volumeUUID: expectedVolume,
                        generatedAt: timestamp, reason: reason)
        }
        guard status == "ok", let total = integer(object["reclaimableBytes"]) else {
            throw Failure("Invalid preview status or byte total.")
        }
        var ids = Set<String>()
        var sum: UInt64 = 0
        var categories: [[String: Any]] = []
        for row in rows {
            guard let id = field(row["id"]), ids.insert(id).inserted, let label = field(row["label"]),
                  let bytes = integer(row["bytes"]), let count = integer(row["itemCount"]),
                  let reason = field(row["safeReason"]) else { throw Failure("Invalid or duplicate preview category.") }
            let (next, overflow) = sum.addingReportingOverflow(bytes)
            guard !overflow else { throw Failure("Preview category bytes overflow the total.") }
            sum = next
            categories.append(["id": id, "label": label, "bytes": bytes, "itemCount": count, "safeReason": reason])
        }
        guard total == sum else { throw Failure("Preview category bytes do not match the total.") }
        return Self(provider: provider, status: status, reclaimableBytes: total, categories: categories, volumeUUID: expectedVolume,
                    generatedAt: timestamp, reason: nil)
    }
}
