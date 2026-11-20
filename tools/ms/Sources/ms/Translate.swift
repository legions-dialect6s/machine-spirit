import AppKit
import Vision
import NaturalLanguage
import Translation

func recognizeText(_ image: URL) throws -> String {
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    request.automaticallyDetectsLanguage = true
    try VNImageRequestHandler(url: image).perform([request])
    return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
}

@MainActor
func translateArea(_ args: [String]) async throws -> Output {
    let parsed = try Arguments(args, values: ["--to", "--image"])
    try parsed.count(0)
    let target = parsed.options["--to"] ?? Locale.preferredLanguages.first ?? "en"
    guard !target.isEmpty, target.count <= 64, target.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
        throw Failure("--to requires a language identifier such as en or es-MX")
    }
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ms-translate-\(UUID().uuidString)", isDirectory: true)
    let file: URL
    if let path = parsed.options["--image"] {
        guard !path.isEmpty else { throw Failure("--image requires a path") }
        file = URL(fileURLWithPath: expandedPath(path))
    } else {
        guard CGPreflightScreenCaptureAccess() else { throw Failure("Screen Recording permission required for area capture") }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        file = temporary.appendingPathComponent("area.png")
    }
    defer { if parsed.options["--image"] == nil { try? FileManager.default.removeItem(at: temporary) } }
    if parsed.options["--image"] == nil {
        _ = try? process("/usr/sbin/screencapture", ["-i", "-x", file.path])
        guard FileManager.default.fileExists(atPath: file.path) else { throw Failure("", exitCode: 11) }
    }
    let original = try recognizeText(file)
    guard !original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw Failure("no text recognized", exitCode: 11) }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(original)
    let source = recognizer.dominantLanguage?.rawValue
    var text = original
    var translated = false
    var note: String?
    if let source {
        let sourceLanguage = Locale.Language(identifier: source), targetLanguage = Locale.Language(identifier: target)
        if sourceLanguage.languageCode == targetLanguage.languageCode {
            note = "Recognized text already matches the target language; copied OCR text."
        } else if #available(macOS 26.0, *) {
            let availability = await LanguageAvailability().status(from: sourceLanguage, to: targetLanguage)
            if availability == .installed {
                do {
                    let session = TranslationSession(installedSource: sourceLanguage, target: targetLanguage)
                    text = try await session.translate(original).targetText
                    translated = true
                } catch { note = "On-device translation unavailable (\(oneLine(error.localizedDescription))); copied OCR text." }
            } else { note = "Language pair is not installed or supported; copied OCR text. No download requested." }
        } else { note = "CLI translation requires macOS 26; copied OCR text." }
    } else { note = "Could not detect the source language; copied OCR text." }
    NSPasteboard.general.clearContents()
    guard NSPasteboard.general.setString(text, forType: .string) else { throw Failure("cannot copy recognized text to clipboard") }
    showHUD([URLQueryItem(name: "style", value: "text"), URLQueryItem(name: "title", value: "\(source ?? "auto")→\(target)\(translated ? "" : " (OCR)")"),
             URLQueryItem(name: "text", value: String(text.prefix(600)))])
    return Output(json: ["text": text, "ocrText": original, "source": source as Any? ?? NSNull(), "target": target,
                         "translated": translated, "copied": true, "notes": note.map { [$0] } ?? []],
                  text: text + (note.map { "\nNote: \($0)" } ?? ""))
}
