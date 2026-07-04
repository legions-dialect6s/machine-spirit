import AppKit

// usage: swift render-art.swift <art.txt> <out.png>
let a = CommandLine.arguments
let text = try! String(contentsOfFile: a[1], encoding: .utf8)
let outPath = a[2]
let font = NSFont(name: "Menlo", size: 20)!
let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
let str = NSAttributedString(string: text, attributes: attrs)
let bounds = str.boundingRect(with: NSSize(width: 100000, height: 100000),
                              options: [.usesLineFragmentOrigin])
let w = Int(ceil(bounds.width)) + 20, h = Int(ceil(bounds.height)) + 20
let img = NSImage(size: NSSize(width: w, height: h))
img.lockFocus()
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: w, height: h).fill()
str.draw(with: NSRect(x: 10, y: 10, width: CGFloat(w - 20), height: CGFloat(h - 20)),
         options: [.usesLineFragmentOrigin])
img.unlockFocus()
guard let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: outPath))
