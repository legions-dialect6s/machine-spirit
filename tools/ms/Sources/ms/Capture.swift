import AppKit
import ImageIO
import UniformTypeIdentifiers
import Darwin

func captureRect(_ value: String) throws -> CGRect {
    let numbers = value.split(separator: ",", omittingEmptySubsequences: false).compactMap { Double($0) }
    guard numbers.count == 4, numbers.allSatisfy({ $0.isFinite && abs($0) <= 1_000_000 }), numbers[2] > 0, numbers[3] > 0 else {
        throw Failure("--rect requires finite x,y,width,height with positive width and height")
    }
    return CGRect(x: numbers[0], y: numbers[1], width: numbers[2], height: numbers[3])
}

func rectArgument(_ rect: CGRect) -> String {
    [rect.minX, rect.minY, rect.width, rect.height].map { String(Double($0)) }.joined(separator: ",")
}

@MainActor
func screenshot(_ args: [String]) throws -> Output {
    let parsed = try Arguments(args, values: ["--screen", "--window", "--rect", "--out"])
    try parsed.count(0)
    guard ["--screen", "--window", "--rect"].filter({ parsed.options[$0] != nil }).count <= 1 else {
        throw Failure("choose only one of --screen, --window or --rect")
    }
    var captureArgs = ["-x", "-t", "png"]
    if let value = parsed.options["--window"] {
        let id = try positiveID(value)
        guard try windowList(allSpaces: true).contains(where: { $0.id == id }) else { throw Failure("unknown window ID \(id)") }
        captureArgs += ["-l\(id)"]
    } else if let value = parsed.options["--screen"] {
        let id = try positiveID(value)
        guard NSScreen.screens.contains(where: { screenID($0) == id }) else { throw Failure("unknown screen ID \(id); use ms screens") }
        // -D takes a display ordinal, not a CGDirectDisplayID. Bounds avoid that mismatch.
        captureArgs += ["-R\(rectArgument(CGDisplayBounds(id)))"]
    } else if let value = parsed.options["--rect"] {
        let rect = try captureRect(value)
        guard NSScreen.screens.contains(where: { CGDisplayBounds(screenID($0)).intersects(rect) }) else {
            throw Failure("capture rectangle does not intersect a screen")
        }
        captureArgs += ["-R\(rectArgument(rect))"]
    } else { captureArgs += ["-m"] }
    guard CGPreflightScreenCaptureAccess() else {
        throw Failure("Screen Recording permission required: enable the calling terminal or agent host in System Settings > Privacy & Security > Screen Recording, then restart it")
    }
    let file: URL
    if let path = parsed.options["--out"] {
        guard !path.isEmpty else { throw Failure("--out requires a path") }
        file = URL(fileURLWithPath: expandedPath(path)).standardizedFileURL
    } else {
        file = FileManager.default.temporaryDirectory.appendingPathComponent("ms-\(UUID().uuidString).png")
    }
    // Reserve a private, non-existing output. Never overwrite an owner file or follow a symlink.
    let fd = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode_t(0o600))
    guard fd >= 0 else { throw Failure("cannot create screenshot output (must not already exist): \(String(cString: strerror(errno)))") }
    Darwin.close(fd)
    do {
        _ = try process("/usr/sbin/screencapture", captureArgs + [file.path])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        guard let source = CGImageSourceCreateWithURL(file as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let width = properties[kCGImagePropertyPixelWidth as String] as? Int,
              let height = properties[kCGImagePropertyPixelHeight as String] as? Int else {
            throw Failure("screencapture did not produce a valid image; check Screen Recording permission")
        }
        return Output(json: ["path": file.path, "width": width, "height": height, "mimeType": "image/png"], text: file.path, imagePath: file.path)
    } catch {
        try? FileManager.default.removeItem(at: file)
        throw error
    }
}

func screenshotImage(_ path: String) throws -> [String: Any] {
    guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: 1568,
            kCGImageSourceCreateThumbnailWithTransform: true,
          ] as CFDictionary) else { throw Failure("cannot downscale screenshot") }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw Failure("cannot encode screenshot PNG")
    }
    CGImageDestinationAddImage(destination, thumbnail, nil)
    guard CGImageDestinationFinalize(destination) else { throw Failure("cannot finalize screenshot PNG") }
    return ["type": "image", "data": (data as Data).base64EncodedString(), "mimeType": "image/png"]
}
