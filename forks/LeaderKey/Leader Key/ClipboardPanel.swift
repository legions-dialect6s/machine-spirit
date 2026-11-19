import Cocoa
import os.log

private final class ClipboardKeyPanel: NSPanel {
  var handleKey: ((NSEvent) -> Bool)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func sendEvent(_ event: NSEvent) {
    if event.type == .keyDown, handleKey?(event) == true { return }
    super.sendEvent(event)
  }
}

/// One reusable nonactivating panel. It can become key for search without making
/// Leader Key the foreground application or losing the intended paste target.
final class ClipboardPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate,
  NSSearchFieldDelegate, NSWindowDelegate
{
  private let history: ClipboardHistory
  private let panel: ClipboardKeyPanel
  private let search = NSSearchField()
  private let table = NSTableView()
  private let footer = NSTextField(labelWithString: "")
  private let countLabel = NSTextField(labelWithString: "")
  private var filtered: [ClipboardHistory.Entry] = []
  private var previousApplication: NSRunningApplication?
  private var session = 0
  private var choosing = false

  init(history: ClipboardHistory) {
    self.history = history
    panel = ClipboardKeyPanel(
      contentRect: NSRect(x: 0, y: 0, width: 520, height: 440),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    super.init()
    panel.title = "Clipboard history"
    panel.isFloatingPanel = true
    panel.isReleasedWhenClosed = false
    panel.hidesOnDeactivate = false
    panel.becomesKeyOnlyIfNeeded = false
    panel.level = .floating
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.appearance = NSAppearance(named: .darkAqua)
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    panel.delegate = self
    panel.handleKey = { [weak self] event in self?.handleKey(event) ?? false }

    let background = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 440))
    background.wantsLayer = true
    background.layer?.backgroundColor = NSColor(calibratedWhite: 0.10, alpha: 1).cgColor
    background.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
    background.layer?.borderWidth = 1
    background.layer?.cornerRadius = 14
    background.layer?.masksToBounds = true
    panel.contentView = background

    let title = NSTextField(labelWithString: "Clipboard history")
    title.font = .systemFont(ofSize: 15, weight: .semibold)
    title.frame = NSRect(x: 18, y: 405, width: 300, height: 22)
    title.autoresizingMask = [.width, .minYMargin]
    background.addSubview(title)
    countLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    countLabel.textColor = .secondaryLabelColor
    countLabel.alignment = .right
    countLabel.frame = NSRect(x: 356, y: 408, width: 146, height: 16)
    countLabel.autoresizingMask = [.minXMargin, .minYMargin]
    background.addSubview(countLabel)
    search.frame = NSRect(x: 18, y: 365, width: 484, height: 30)
    search.placeholderString = "Search clipboard…"
    search.sendsSearchStringImmediately = true
    search.delegate = self
    search.autoresizingMask = [.width, .minYMargin]
    search.setAccessibilityLabel("Search clipboard history")
    background.addSubview(search)

    let scroll = NSScrollView(frame: NSRect(x: 8, y: 48, width: 504, height: 307))
    scroll.autoresizingMask = [.width, .height]
    scroll.hasVerticalScroller = true
    scroll.drawsBackground = false
    table.frame = scroll.bounds
    table.autoresizingMask = [.width]
    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
    column.width = scroll.contentSize.width
    column.resizingMask = .autoresizingMask
    table.addTableColumn(column)
    table.headerView = nil
    table.rowHeight = 50
    table.intercellSpacing = NSSize(width: 0, height: 4)
    table.backgroundColor = .clear
    table.style = .plain
    table.selectionHighlightStyle = .regular
    table.allowsMultipleSelection = false
    table.allowsEmptySelection = false
    table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(pasteSelection)
    table.setAccessibilityLabel("Clipboard entries")
    scroll.documentView = table
    background.addSubview(scroll)
    footer.frame = NSRect(x: 18, y: 12, width: 484, height: 26)
    footer.font = .systemFont(ofSize: 10)
    footer.textColor = .secondaryLabelColor
    footer.maximumNumberOfLines = 2
    footer.autoresizingMask = [.width]
    background.addSubview(footer)

    history.onChange = { [weak self] in
      guard let self, self.panel.isVisible else { return }
      self.reload(preserveSelection: true)
    }
    history.onThumbnail = { [weak self] id in
      guard let self, self.panel.isVisible,
        let row = self.filtered.firstIndex(where: { $0.id == id })
      else { return }
      self.table.reloadData(
        forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0))
    }
  }

  func show(previousApplication: NSRunningApplication?) {
    if panel.isVisible {
      panel.makeKeyAndOrderFront(nil)
      panel.makeFirstResponder(search)
      return
    }
    self.previousApplication = previousApplication
    session += 1
    choosing = false
    search.stringValue = ""
    let mouse = NSEvent.mouseLocation
    guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) }) ?? NSScreen.main
    else { return }
    let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
    let width = min(520, bounds.width)
    let height = min(440, bounds.height)
    let origin = NSPoint(
      x: max(bounds.minX, min(mouse.x - width / 2, bounds.maxX - width)),
      y: max(bounds.minY, min(mouse.y - height + 24, bounds.maxY - height)))
    panel.setFrame(
      NSRect(origin: origin, size: NSSize(width: width, height: height)), display: false)
    reload(preserveSelection: false)
    panel.makeKeyAndOrderFront(nil)
    panel.makeFirstResponder(search)
    os_log("Clipboard panel shown: entries=%d targetPid=%d", history.entries.count, previousApplication?.processIdentifier ?? -1)
  }

  func dismiss() {
    session += 1
    choosing = false
    panel.orderOut(nil)
  }

  func windowDidResignKey(_ notification: Notification) {
    if panel.isVisible { dismiss() }
  }

  func controlTextDidChange(_ obj: Notification) { reload(preserveSelection: false) }

  private func reload(preserveSelection: Bool) {
    let selected =
      preserveSelection && filtered.indices.contains(table.selectedRow)
      ? filtered[table.selectedRow].id : nil
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    filtered = history.entries.filter { entry in
      Self.matches(
        query,
        in: entry.kind == .image
          ? "image" : (entry.text ?? (entry.fileURLs ?? []).joined(separator: " ")))
    }.sorted { lhs, rhs in lhs.pinned == rhs.pinned ? lhs.date > rhs.date : lhs.pinned }
    table.reloadData()
    if !filtered.isEmpty {
      let row = selected.flatMap { id in filtered.firstIndex(where: { $0.id == id }) } ?? 0
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      table.scrollRowToVisible(row)
    }
    countLabel.stringValue = "\(filtered.count) / \(history.entries.count)"
    if !history.loaded {
      footer.stringValue = "Loading history…"
    } else if filtered.isEmpty {
      footer.stringValue =
        query.isEmpty
        ? "Copy text, files or an image to begin. Esc closes." : "No matches. Esc closes."
    } else {
      footer.stringValue =
        "↵ Paste   ⌥↵ Copy   ⌘1–9 Choose   ⌘P Pin   ⌫ Delete (empty search)   Esc Close"
    }
  }

  static func matches(_ query: String, in value: String) -> Bool {
    guard !query.isEmpty else { return true }
    let text = value.lowercased()
    if text.contains(query) { return true }
    var position = text.startIndex
    for character in query {
      guard let match = text[position...].firstIndex(of: character) else { return false }
      position = text.index(after: match)
    }
    return true
  }

  func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView?
  {
    guard filtered.indices.contains(row) else { return nil }
    let identifier = NSUserInterfaceItemIdentifier("ClipboardCell")
    let cell =
      tableView.makeView(withIdentifier: identifier, owner: self) as? ClipboardCell
      ?? ClipboardCell()
    cell.identifier = identifier
    let entry = filtered[row]
    cell.title.stringValue = String(entry.preview.prefix(500))
    cell.detail.stringValue =
      entry.kind == .files
      ? "\(entry.fileURLs?.count ?? 0) file(s)"
      : (entry.kind == .image ? "Image · PNG" : "Text" + (entry.rtf == nil ? "" : " · Rich text"))
    cell.shortcut.stringValue = (entry.pinned ? "📌  " : "") + (row < 9 ? "⌘\(row + 1)" : "")
    cell.icon.image =
      entry.kind == .image
      ? history.thumbnail(for: entry)
      : NSImage(
        systemSymbolName: entry.kind == .files ? "doc.on.doc" : "text.alignleft",
        accessibilityDescription: nil)
    return cell
  }

  private func handleKey(_ event: NSEvent) -> Bool {
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.keyCode == 53 {
      dismiss()
      return true
    }
    if flags.contains(.command), let char = event.charactersIgnoringModifiers?.lowercased() {
      if let number = Int(char), (1...9).contains(number) {
        if filtered.indices.contains(number - 1) {
          choose(row: number - 1, copyOnly: flags.contains(.option))
        }
        return true
      }
      if char == "p" {
        if filtered.indices.contains(table.selectedRow) {
          history.togglePin(filtered[table.selectedRow].id)
        }
        return true
      }
    }
    switch event.keyCode {
    case 125, 126:
      guard !filtered.isEmpty else { return true }
      let row = max(0, min(filtered.count - 1, table.selectedRow + (event.keyCode == 125 ? 1 : -1)))
      table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
      table.scrollRowToVisible(row)
      return true
    case 36, 76:
      choose(row: table.selectedRow, copyOnly: flags.contains(.option))
      return true
    case 51, 117:
      if search.stringValue.isEmpty, filtered.indices.contains(table.selectedRow) {
        history.delete(filtered[table.selectedRow].id)
        return true
      }
    default: break
    }
    return false
  }

  @objc private func pasteSelection() { choose(row: table.selectedRow, copyOnly: false) }

  private func choose(row: Int, copyOnly: Bool) {
    guard !choosing, filtered.indices.contains(row) else { return }
    choosing = true
    let version = session
    let target = previousApplication
    history.copy(filtered[row]) { [weak self] success in
      guard let self, self.session == version, self.panel.isVisible else { return }
      self.choosing = false
      guard success else {
        self.footer.stringValue = "Could not read this item. The clipboard was preserved."
        return
      }
      if !copyOnly && !AXIsProcessTrusted() {
        self.footer.stringValue =
          "Copied. Enable MachineSpirit Leader Key in Privacy & Security → Accessibility to paste."
        return
      }
      self.dismiss()
      guard !copyOnly, let target, !target.isTerminated,
        target.processIdentifier != ProcessInfo.processInfo.processIdentifier
      else { return }
      target.activate(options: [])
      let pasteSession = self.session
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        guard let self, self.session == pasteSession,
          NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
        else {
          os_log("Clipboard: paste skipped because target focus changed; item is copied")
          return
        }
        let source = CGEventSource(stateID: .privateState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
        os_log("Clipboard: paste sent to pid=%d", target.processIdentifier)
      }
    }
  }
}

private final class ClipboardCell: NSTableCellView {
  let icon = NSImageView()
  let title = NSTextField(labelWithString: "")
  let detail = NSTextField(labelWithString: "")
  let shortcut = NSTextField(labelWithString: "")

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    icon.imageScaling = .scaleProportionallyUpOrDown
    title.font = .systemFont(ofSize: 13)
    title.lineBreakMode = .byTruncatingTail
    detail.font = .systemFont(ofSize: 10)
    detail.textColor = .secondaryLabelColor
    shortcut.font = .systemFont(ofSize: 11)
    shortcut.textColor = .secondaryLabelColor
    shortcut.alignment = .right
    [icon, title, detail, shortcut].forEach { addSubview($0) }
  }
  convenience init() { self.init(frame: NSRect(x: 0, y: 0, width: 480, height: 50)) }
  required init?(coder: NSCoder) { nil }
  override func layout() {
    super.layout()
    icon.frame = NSRect(x: 10, y: 7, width: 36, height: 36)
    title.frame = NSRect(x: 58, y: 26, width: max(0, bounds.width - 140), height: 18)
    detail.frame = NSRect(x: 58, y: 8, width: max(0, bounds.width - 140), height: 14)
    shortcut.frame = NSRect(x: max(0, bounds.width - 76), y: 17, width: 64, height: 18)
  }
}
