import AppKit
import SwiftUI

@MainActor
final class TypingOverlay {
  private let state: AppState
  private let panel: PassivePanel
  private var visibilityRevision = 0
  private var hiding = false

  init(state: AppState) {
    self.state = state
    panel = PassivePanel(contentRect: .zero,
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.ignoresMouseEvents = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.animationBehavior = .none
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    // MainWindow's isFloatingPanel=true gives Leader Key level 3. Stay one
    // below it (2), even if our orderFrontRegardless happens after its show.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    let host = NSHostingView(rootView: OverlayRoot().environment(state).preferredColorScheme(.dark))
    host.sizingOptions = []
    host.wantsLayer = true
    host.layer?.backgroundColor = NSColor.clear.cgColor
    panel.contentView = host
  }

  func show(path: String, screen frame: String?) {
    guard let screen = Self.screen(matching: frame) else { return }
    visibilityRevision += 1
    let wasVisible = state.overlayVisible
    let wasHiding = hiding
    hiding = false
    state.overlayNodeID = state.route(atPath: path)?.last ?? state.model?.id
    state.overlayVisible = true
    let visible = screen.visibleFrame
    let size = NSSize(width: visible.width * 0.6, height: visible.height * 0.6)
    panel.setFrame(NSRect(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2,
      width: size.width, height: size.height), display: true)
    // A path update changes only the graph/camera; no new fade or activation.
    if wasVisible {
      if wasHiding {
        NSAnimationContext.runAnimationGroup { context in
          context.duration = 0.12
          panel.animator().alphaValue = 1
        }
      }
      return
    }
    panel.alphaValue = 0
    panel.orderFrontRegardless()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      panel.animator().alphaValue = 1
    }
  }

  func hide() {
    guard state.overlayVisible, !hiding else { return }
    hiding = true
    visibilityRevision += 1
    let revision = visibilityRevision
    // Retain the final frame during the fade, then remove the graph tree.
    // A newer show invalidates this completion (rapid hide/show is common).
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.12
      panel.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.visibilityRevision == revision else { return }
        self.panel.orderOut(nil)
        self.hiding = false
        self.state.overlayVisible = false
        self.state.sleepIfHidden()
      }
    }
  }

  private static func screen(matching text: String?) -> NSScreen? {
    if let values = text?.split(separator: ",").compactMap({ Double($0) }), values.count == 4 {
      // The contract rounds AppKit coordinates to integer strings.
      if let match = NSScreen.screens.first(where: {
        zip([$0.frame.origin.x, $0.frame.origin.y, $0.frame.width, $0.frame.height], values)
          .allSatisfy { abs($0.0 - $0.1) < 1 }
      }) { return match }
    }
    return NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
  }
}

private final class PassivePanel: NSPanel {
  override var canBecomeKey: Bool { false }
  override var canBecomeMain: Bool { false }
}

private struct OverlayRoot: View {
  @Environment(AppState.self) private var state
  var body: some View {
    if state.overlayVisible { GraphView(mode: .overlay) }
  }
}
