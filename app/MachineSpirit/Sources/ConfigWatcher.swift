import Foundation

/// Event-driven, atomic-replace-safe watch. Missing configs are watched via
/// the nearest existing ancestor, so a first install recovers without polling.
@MainActor
final class ConfigWatcher {
  private let url: URL
  private let onChange: () -> Void
  private var sources: [DispatchSourceFileSystemObject] = []
  private var signature: Signature?
  private var active = true

  private struct Signature: Equatable {
    var modified: Date?
    var inode: UInt64?
    var size: UInt64?
  }

  init(url: URL, onChange: @escaping () -> Void) {
    self.url = url
    self.onChange = onChange
    signature = currentSignature()
    arm()
  }

  func stop() {
    active = false
    cancelSources()
  }

  private func cancelSources() {
    sources.forEach { $0.cancel() }
    sources.removeAll()
  }

  /// Suppress the pen's own successful write, already re-imported by AppState.
  func acknowledgeCurrent() { signature = currentSignature() }

  private func currentSignature() -> Signature? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
    return Signature(modified: attributes[.modificationDate] as? Date,
      inode: attributes[.systemFileNumber] as? UInt64, size: attributes[.size] as? UInt64)
  }

  private func arm() {
    guard active else { return }
    cancelSources()
    var directory = url.deletingLastPathComponent()
    while !FileManager.default.fileExists(atPath: directory.path), directory.path != "/" {
      directory.deleteLastPathComponent()
    }
    for watchedURL in [directory, url] {
      let descriptor = open(watchedURL.path, O_EVTONLY)
      guard descriptor >= 0 else { continue }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .rename, .delete, .attrib], queue: .main)
      source.setCancelHandler { close(descriptor) }
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated {
          guard let self, self.active else { return }
          self.arm()
          let updated = self.currentSignature()
          guard updated != self.signature else { return }
          self.signature = updated
          self.onChange()
        }
      }
      sources.append(source)
      source.resume()
    }
  }
}
