import AppKit

let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let rect = NSRect(x: 60, y: 60, width: 904, height: 904)
let background = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
NSColor(calibratedRed: 0.1, green: 0.115, blue: 0.17, alpha: 1).setFill()
background.fill()
NSColor(calibratedRed: 0.76, green: 0.78, blue: 1, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 236, y: 236, width: 552, height: 552)).fill()
NSColor(calibratedRed: 0.1, green: 0.115, blue: 0.17, alpha: 1).setFill()
NSBezierPath(roundedRect: NSRect(x: 300, y: 536, width: 424, height: 190), xRadius: 95, yRadius: 95)
  .fill()
NSColor(calibratedRed: 0.43, green: 0.87, blue: 0.7, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 748, y: 748, width: 86, height: 86)).fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(
  to: URL(fileURLWithPath: CommandLine.arguments[1]))
