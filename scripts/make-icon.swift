// Renders Resources/AppIcon.icns: a vector telescope (same as the menu bar icon)
// on a sky-blue rounded square. Run from the repo root: swift scripts/make-icon.swift
import AppKit

// Shared vector artwork, exported as PDF for the menu bar.
let telescope = NSImage(size: NSSize(width: 24, height: 24), flipped: false) { _ in
    NSColor.white.setFill()
    NSColor.white.setStroke()
    let tube = NSBezierPath()
    tube.move(to: NSPoint(x: 3, y: 14))
    tube.line(to: NSPoint(x: 17, y: 22))
    tube.line(to: NSPoint(x: 21, y: 15))
    tube.line(to: NSPoint(x: 7, y: 7))
    tube.close()
    tube.fill()
    let details = NSBezierPath()
    for (a, b) in [
        (NSPoint(x: 17, y: 22), NSPoint(x: 21, y: 15)),
        (NSPoint(x: 2, y: 10), NSPoint(x: 5, y: 11.7)),
        (NSPoint(x: 12, y: 10), NSPoint(x: 12, y: 3)),
        (NSPoint(x: 12, y: 10), NSPoint(x: 6, y: 2)),
        (NSPoint(x: 12, y: 10), NSPoint(x: 18, y: 2)),
    ] {
        details.move(to: a)
        details.line(to: b)
    }
    details.lineWidth = 2
    details.lineCapStyle = .round
    details.stroke()
    return true
}

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)

    // macOS icon grid: 824/1024 body with ~185/1024 corner radius.
    let inset = s * 100 / 1024
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let shape = NSBezierPath(roundedRect: body, xRadius: s * 185 / 1024, yRadius: s * 185 / 1024)
    NSGradient(colors: [
        NSColor(red: 0.36, green: 0.72, blue: 0.98, alpha: 1),
        NSColor(red: 0.07, green: 0.29, blue: 0.62, alpha: 1),
    ])!.draw(in: shape, angle: -90)

    let side = body.width * 0.70
    telescope.draw(in: NSRect(x: (s - side) / 2, y: (s - side) / 2, width: side, height: side))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { exit(iconutil.terminationStatus) }
let pdf = NSMutableData()
var mediaBox = CGRect(x: 0, y: 0, width: 24, height: 24)
let consumer = CGDataConsumer(data: pdf)!
let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil)!
context.beginPDFPage(nil)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
telescope.draw(in: mediaBox)
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()
try (pdf as Data).write(to: URL(fileURLWithPath: "Resources/Telescope.pdf"))
