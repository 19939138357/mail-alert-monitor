// Entirely synthetic OCR fixture. No user mail or screenshots are included.
import AppKit
import Foundation
let output = CommandLine.arguments[1]
let image = NSImage(size: NSSize(width: 900, height: 330))
image.lockFocus()
NSColor.white.setFill()
NSBezierPath(rect: CGRect(x: 0, y: 0, width: 900, height: 330)).fill()
let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 22), .foregroundColor: NSColor.black]
for (index, y) in [270, 170, 30].enumerated() {
    NSColor(calibratedRed: 0.18, green: 0.62, blue: 1, alpha: 1).setFill()
    NSBezierPath(ovalIn: CGRect(x: 16, y: y + 7, width: 14, height: 14)).fill()
    ("sender\(index + 1)@example.com" as NSString).draw(at: NSPoint(x: 110, y: y), withAttributes: attributes)
    if index < 2 { ("Synthetic message \(index + 1)" as NSString).draw(at: NSPoint(x: 110, y: y - 31), withAttributes: attributes) }
}
image.unlockFocus()
guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
      let data = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else { fatalError("Cannot render synthetic sample") }
try data.write(to: URL(fileURLWithPath: output), options: .atomic)
