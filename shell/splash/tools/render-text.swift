import AppKit

// usage: swift render-text.swift <font.ttf> <text> <out.png>
let a = CommandLine.arguments
guard a.count == 4,
      let dp = CGDataProvider(filename: a[1]),
      let cg = CGFont(dp) else { exit(1) }
let text = a[2], outPath = a[3]
let ctFont = CTFontCreateWithGraphicsFont(cg, 140, nil, nil)
let attrs: [NSAttributedString.Key: Any] = [.font: ctFont, .foregroundColor: NSColor.white]
let str = NSAttributedString(string: text, attributes: attrs)
let b = str.size()
let w = Int(ceil(b.width)) + 40, h = Int(ceil(b.height)) + 40
let img = NSImage(size: NSSize(width: w, height: h))
img.lockFocus()
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()
str.draw(at: NSPoint(x: 20, y: 20))
img.unlockFocus()
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
