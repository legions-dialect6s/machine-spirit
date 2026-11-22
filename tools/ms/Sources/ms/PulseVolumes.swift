import Darwin
import Foundation

struct PulseVolumeTarget: Codable {
    let name: String
    let volumeUUID: UUID
    var projectProvider: String? = nil

    static func configured(at file: URL) throws -> [Self] {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            if errno == ENOENT { return [] }
            throw Failure("Cannot open Pulse volumes.json")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_mode & 0o022 == 0, info.st_size <= 65536,
              let data = try handle.read(upToCount: 65537), data.count <= 65536,
              let targets = try? JSONDecoder().decode([Self].self, from: data) else {
            throw Failure("Cannot verify or decode Pulse volumes.json")
        }
        guard targets.allSatisfy({ !$0.name.isEmpty && !$0.name.contains("/") && !$0.name.contains("\0") && ![".", ".."].contains($0.name) }),
              Set(targets.map(\.name)).count == targets.count,
              Set(targets.map(\.volumeUUID)).count == targets.count,
              targets.compactMap(\.projectProvider).count <= 1,
              targets.compactMap(\.projectProvider).allSatisfy(ProjectDiskPreview.validProvider) else {
            throw Failure("Pulse volumes.json requires distinct mount names, volume UUIDs and at most one valid project preview provider")
        }
        return targets
    }
}

struct PulseVolumeReading: Codable {
    enum Status: String, Codable { case mounted, absent, differentVolume, unavailable }
    let name: String
    let volumeUUID: UUID
    var status: Status
    var freeBytes: UInt64?
    var capacityBytes: UInt64?
    var reviewThresholdBytes: UInt64? { capacityBytes.map { $0 / 10 } }

    var json: [String: Any] {
        ["name": name, "volumeUUID": volumeUUID.uuidString, "status": status.rawValue,
         "freeBytes": freeBytes as Any? ?? NSNull(), "capacityBytes": capacityBytes as Any? ?? NSNull(),
         "reviewThresholdBytes": reviewThresholdBytes as Any? ?? NSNull()]
    }

    static func read(_ targets: [PulseVolumeTarget], refresh: Bool) -> [Self] {
        guard !targets.isEmpty else { return [] }
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&mounts, MNT_NOWAIT)
        defer { free(mounts) }
        var mounted: [String: statfs] = [:]
        if let mounts, count > 0 {
            for var fs in UnsafeBufferPointer(start: mounts, count: Int(count)) where fs.f_flags & UInt32(MNT_LOCAL) != 0 {
                let path = withUnsafeBytes(of: &fs.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
                mounted[path] = fs
            }
        }
        return targets.map { target in
            let path = "/Volumes/" + target.name
            var result = Self(name: target.name, volumeUUID: target.volumeUUID, status: .unavailable)
            guard count > 0 else { return result }
            guard var fs = mounted[path] else {
                result.status = .absent
                return result
            }
            // Pin an exact mount from the kernel's table before reading its persistent identity.
            let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
            guard fd >= 0 else { return result }
            defer { close(fd) }
            var attrs = attrlist()
            attrs.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
            attrs.commonattr = UInt32(ATTR_CMN_FSID)
            attrs.volattr = ATTR_VOL_INFO | UInt32(ATTR_VOL_UUID)
            // getattrlist returns packed 4-byte-aligned fields in attribute order.
            let fsidOffset = MemoryLayout<UInt32>.size
            let uuidOffset = fsidOffset + MemoryLayout<fsid_t>.size
            let size = uuidOffset + MemoryLayout<uuid_t>.size
            var bytes = [UInt8](repeating: 0, count: size)
            let uuid = bytes.withUnsafeMutableBytes { buffer -> UUID? in
                guard fgetattrlist(fd, &attrs, buffer.baseAddress, size, 0) == 0,
                      buffer.loadUnaligned(as: UInt32.self) == size,
                      buffer.loadUnaligned(fromByteOffset: fsidOffset, as: fsid_t.self).val == fs.f_fsid.val
                else { return nil }
                return UUID(uuid: buffer.loadUnaligned(fromByteOffset: uuidOffset, as: uuid_t.self))
            }
            guard let uuid else { return result }
            guard uuid == target.volumeUUID else {
                result.status = .differentVolume
                return result
            }
            // Fresh exFAT space queries can take seconds. Hourly collection uses the mount table's cache.
            if refresh && fstatfs(fd, &fs) != 0 { return result }
            guard fs.f_bsize > 0, fs.f_blocks > 0 else { return result }
            result.status = .mounted
            result.freeBytes = fs.f_bavail * UInt64(fs.f_bsize)
            result.capacityBytes = fs.f_blocks * UInt64(fs.f_bsize)
            return result
        }
    }
}

/// Keep histories separate even if the owner later reuses a name for a replacement disk.
func pulseVolumeHistory(_ rows: [PulseSnapshot]) -> [[String: Any]] {
    let samples = rows.flatMap { row in (row.externalVolumes ?? []).map { (time: row.timestamp, volume: $0) } }
    let groups = Dictionary(grouping: samples) { $0.volume.volumeUUID }
    return groups.values.map { group in
        let last = group[group.count - 1]
        let measured = group.compactMap { sample in sample.volume.freeBytes.map { (time: sample.time, bytes: $0) } }
        var change: Double?
        if let first = measured.first, let end = measured.last, end.time != first.time {
            change = Double(end.bytes) - Double(first.bytes)
        }
        var output = last.volume.json
        output["latestSampleAt"] = last.time
        output["latestMeasuredAt"] = measured.last?.time as Any? ?? NSNull()
        output["latestMeasuredFreeBytes"] = measured.last?.bytes as Any? ?? NSNull()
        output["freeDiskChangeBytes"] = change as Any? ?? NSNull()
        output["measuredSamples"] = measured.count
        output["unavailableSamples"] = group.count - measured.count
        return output
    }.sorted { ($0["name"] as? String ?? "", $0["volumeUUID"] as? String ?? "") <
               ($1["name"] as? String ?? "", $1["volumeUUID"] as? String ?? "") }
}
