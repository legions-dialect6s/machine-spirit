// Concatenate ClipboardPanel.swift + this file into one temporary Swift file,
// then compile with ClipboardHistory.swift. The extension accesses private UI
// only in the test compilation; no test hook ships in the app.
import Cocoa

extension ClipboardPanel {
  func verifyLayoutAndRender(to url: URL) throws {
    reload(preserveSelection: false)
    panel.contentView!.layoutSubtreeIfNeeded()
    table.layoutSubtreeIfNeeded()
    let cell = table.view(atColumn: 0, row: 0, makeIfNecessary: true) as! ClipboardCell
    cell.layoutSubtreeIfNeeded()
    print("LAYOUT column=\(table.tableColumns[0].width) cell=\(cell.bounds.width) text=\(cell.title.frame.width)")
    fflush(stdout)
    // Validate after rendering below.
    search.stringValue = "beta clipboard entry"
    reload(preserveSelection: false)
    precondition(filtered.count == 1 && filtered[0].text == "Beta clipboard entry")
    search.stringValue = ""
    reload(preserveSelection: false)
    table.layoutSubtreeIfNeeded()
    for row in 0..<filtered.count {
      _ = table.rowView(atRow: row, makeIfNecessary: true)
      let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true)
      cell?.layoutSubtreeIfNeeded()
    }
    panel.display()
    let view = panel.contentView!
    let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
    view.cacheDisplay(in: view.bounds, to: rep)
    try rep.representation(using: .png, properties: [:])!.write(to: url)
    precondition(cell.title.frame.width > 200)
    print("PASS native table layout, fuzzy filtering, rendered panel (no window ordered onscreen)")
  }
}

@main struct ClipboardPanelSmoke {
  static func main() throws {
    _ = NSApplication.shared
    let pb = NSPasteboard(name: .init("ms-clipboard-panel-\(UUID().uuidString)"))
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ms-clipboard-panel-\(UUID().uuidString)")
    let history = ClipboardHistory(pasteboard: pb, directory: folder)
    defer { history.stop(); pb.releaseGlobally(); try? FileManager.default.removeItem(at: folder) }
    history.start()
    let deadline = Date().addingTimeInterval(10)
    while !history.loaded && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    precondition(history.loaded)
    for value in ["Alpha clipboard preview — clean native typography", "Beta clipboard entry"] {
      pb.clearContents(); pb.setString(value, forType: .string); history.poll()
      while history.entries.first?.text != value && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
      precondition(history.entries.first?.text == value)
    }
    history.togglePin(history.entries[1].id)
    let panel = ClipboardPanel(history: history)
    try panel.verifyLayoutAndRender(to: URL(fileURLWithPath: "/private/tmp/ms-clipboard-panel.png"))
  }
}
