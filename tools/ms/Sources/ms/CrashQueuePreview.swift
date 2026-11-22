import Darwin
import Foundation

/// On demand only. The directory descriptor pins lookups to the enumerated queue.
struct CrashQueuePreview {
    private struct Pair {
        var dumpInode: ino_t?
        var sidecarInode: ino_t?
    }

    let cutoff: Date
    private(set) var eligiblePairs = 0
    private(set) var eligibleAllocatedBytes: UInt64 = 0
    private(set) var recentPairs = 0
    private(set) var unpairedEntries = 0
    private(set) var unrecognizedEntries = 0
    private(set) var unsafeOrChangedPairs = 0
    private(set) var oldestPairAt: Date?
    private(set) var newestPairAt: Date?

    static func read(at directory: URL, now: Date = Date()) throws -> Self {
        let fd = open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("Cannot open Codex pending crash queue: \(String(cString: strerror(errno)))") }
        guard let stream = fdopendir(fd) else {
            let reason = String(cString: strerror(errno))
            close(fd)
            throw Failure("Cannot enumerate Codex pending crash queue: \(reason)")
        }
        defer { closedir(stream) }
        var initial = stat()
        guard fstat(fd, &initial) == 0, initial.st_uid == getuid() else {
            throw Failure("Cannot verify ownership of the Codex pending crash queue")
        }

        var review = Self(cutoff: now.addingTimeInterval(-7 * 86_400))
        var pairs: [String: Pair] = [:]
        let sidecarSuffix = "_sidecar.json"
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw Failure("Reading the Codex crash queue failed: \(String(cString: strerror(errno)))") }
                break
            }
            let name = withUnsafeBytes(of: &entry.pointee.d_name) {
                String(decoding: $0.prefix(Int(entry.pointee.d_namlen)), as: UTF8.self)
            }
            if name == "." || name == ".." { continue }
            let isDump = name.hasSuffix(".dmp")
            guard isDump || name.hasSuffix(sidecarSuffix) else {
                review.unrecognizedEntries += 1
                continue
            }
            let stem = String(name.dropLast(isDump ? 4 : sidecarSuffix.count))
            guard let uuid = UUID(uuidString: stem), uuid.uuidString.lowercased() == stem else {
                review.unrecognizedEntries += 1
                continue
            }
            if isDump { pairs[stem, default: Pair()].dumpInode = entry.pointee.d_ino }
            else { pairs[stem, default: Pair()].sidecarInode = entry.pointee.d_ino }
        }

        func metadata(_ name: String, inode: ino_t) -> stat? {
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_ino == inode,
                  info.st_dev == initial.st_dev, info.st_uid == getuid(), info.st_nlink == 1,
                  info.st_mode & S_IFMT == S_IFREG, info.st_blocks >= 0 else { return nil }
            return info
        }
        func modified(_ info: stat) -> Date {
            Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9)
        }
        for (stem, pair) in pairs {
            guard let dumpInode = pair.dumpInode, let sidecarInode = pair.sidecarInode else {
                review.unpairedEntries += 1
                continue
            }
            guard let dump = metadata(stem + ".dmp", inode: dumpInode),
                  let sidecar = metadata(stem + sidecarSuffix, inode: sidecarInode) else {
                review.unsafeOrChangedPairs += 1
                continue
            }
            // Both files must predate the cutoff. Sidecars can be updated separately.
            let pairAt = max(modified(dump), modified(sidecar))
            review.oldestPairAt = min(review.oldestPairAt ?? pairAt, pairAt)
            review.newestPairAt = max(review.newestPairAt ?? pairAt, pairAt)
            if pairAt < review.cutoff {
                review.eligiblePairs += 1
                review.eligibleAllocatedBytes += (UInt64(dump.st_blocks) + UInt64(sidecar.st_blocks)) * 512
            } else {
                review.recentPairs += 1
            }
        }
        var final = stat()
        guard fstat(fd, &final) == 0, initial.st_mtimespec.tv_sec == final.st_mtimespec.tv_sec,
              initial.st_mtimespec.tv_nsec == final.st_mtimespec.tv_nsec else {
            throw Failure("The crash queue changed during the preview. Run the preview again.")
        }
        return review
    }

    var output: Output {
        let lines = ["Codex crash queue • seven-day retention",
                     "Eligible pairs: \(eligiblePairs), \(eligibleAllocatedBytes) allocated bytes",
                     "Cutoff (UTC): \(cutoff.ISO8601Format())",
                     "Oldest / newest complete pair (UTC): \(oldestPairAt?.ISO8601Format() ?? "none") / \(newestPairAt?.ISO8601Format() ?? "none")",
                     "Kept recent pairs: \(recentPairs)",
                     "Skipped: \(unpairedEntries) unpaired entries, \(unrecognizedEntries) unrecognized entries, \(unsafeOrChangedPairs) unsafe or changed pairs"]
        return Output(json: ["retentionDays": 7, "cutoff": cutoff.ISO8601Format(),
                             "eligiblePairs": eligiblePairs, "eligibleAllocatedBytes": eligibleAllocatedBytes,
                             "recentPairs": recentPairs, "unpairedEntries": unpairedEntries,
                             "unrecognizedEntries": unrecognizedEntries, "unsafeOrChangedPairs": unsafeOrChangedPairs,
                             "oldestPairAt": oldestPairAt?.ISO8601Format() as Any? ?? NSNull(),
                             "newestPairAt": newestPairAt?.ISO8601Format() as Any? ?? NSNull()], text: lines.joined(separator: "\n"))
    }
}
