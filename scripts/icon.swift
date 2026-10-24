import AppKit
let size = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let rect = NSRect(x: 60, y: 60, width: 904, height: 904)
let shape = NSBezierPath(roundedRect: rect, xRadius: 205, yRadius: 205)
NSGradient(starting: NSColor(calibratedRed: 0.05, green: 0.73, blue: 0.83, alpha: 1), ending: NSColor(calibratedRed: 0.03, green: 0.28, blue: 0.45, alpha: 1))!.draw(in: shape, angle: -50)
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 570, y: 850)); bolt.line(to: NSPoint(x: 300, y: 470)); bolt.line(to: NSPoint(x: 482, y: 470))
bolt.line(to: NSPoint(x: 430, y: 180)); bolt.line(to: NSPoint(x: 747, y: 590)); bolt.line(to: NSPoint(x: 552, y: 590)); bolt.close()
NSColor.white.setFill(); bolt.fill()
image.unlockFocus()
let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
