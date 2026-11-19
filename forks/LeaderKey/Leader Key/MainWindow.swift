import Cocoa
import QuartzCore
import SwiftUI
import os.log

class PanelWindow: NSPanel {
  init(contentRect: NSRect) {
    super.init(
      contentRect: contentRect,
      styleMask: [.nonactivatingPanel],
      backing: .buffered, defer: false
    )

    isFloatingPanel = true
    isReleasedWhenClosed = false
    animationBehavior = .none
    backgroundColor = .clear
    isOpaque = false
  }
}

class MainWindow: PanelWindow, NSWindowDelegate {
  override var acceptsFirstResponder: Bool { return true }
  override var canBecomeKey: Bool { return true }
  override var canBecomeMain: Bool { return true }

  var hasCheatsheet: Bool { return true }
  private var normalShadow: Bool?

  /// Hide only the theme content. Window alpha stays available for theme fades
  /// and the panel remains key; the separate cheatsheet is untouched.
  func updateOverlayAppearance() {
    let hidden = UserDefaults.standard.bool(forKey: "msGraphOverlayEnabled")
    if normalShadow == nil { normalShadow = hasShadow }
    contentView?.alphaValue = hidden ? 0 : 1
    backgroundColor = .clear
    isOpaque = false
    hasShadow = hidden ? false : normalShadow ?? true
    invalidateShadow()
  }

  func windowDidBecomeKey(_ notification: Notification) {
    os_log(
      "Leader capture: key=%d contentAlpha=%.1f shadow=%d", isKeyWindow ? 1 : 0,
      contentView?.alphaValue ?? -1, hasShadow ? 1 : 0)
  }

  var controller: Controller

  required init(controller: Controller) {
    // Here to provide general interface
    // Themes should call super.init(controller:, contentRect:) to get a frame as well
    self.controller = controller
    super.init(contentRect: NSRect())
  }

  init(controller: Controller, contentRect: NSRect) {
    self.controller = controller
    super.init(contentRect: contentRect)
    delegate = self
  }

  func windowDidResignKey(_ notification: Notification) {
    controller.hide()
  }

  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if event.modifierFlags.contains(.command) {
      controller.keyDown(with: event)
      return true
    }
    return false
  }

  override func keyDown(with event: NSEvent) {
    controller.keyDown(with: event)
  }

  func show(on screen: NSScreen, after: (() -> Void)?) {
    makeKeyAndOrderFront(nil)
    after?()
  }

  func hide(after: (() -> Void)?) {
    close()
    after?()
  }

  func notFound() {
  }

  func cheatsheetOrigin(cheatsheetSize: NSSize) -> NSPoint {
    return NSPoint(x: 0, y: 0)
  }
}
