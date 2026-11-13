// Run from the repo root: swift scripts/make-icon.swift
import AppKit

/// The telescope, drawn in a 24 × 24 box with the origin at the bottom left.
func drawTelescope(in rect: NSRect, color: NSColor) {
    let scale = rect.width / 24
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: rect.minX + x * scale, y: rect.minY + y * scale) }

    let angle = 31 * CGFloat.pi / 180
    let pivot = (x: CGFloat(11.2), y: CGFloat(12.6))
    func onTube(_ along: CGFloat, _ across: CGFloat) -> NSPoint {
        point(pivot.x + along * cos(angle) - across * sin(angle), pivot.y + along * sin(angle) + across * cos(angle))
    }
    func segment(from start: CGFloat, to end: CGFloat, startWidth: CGFloat, endWidth: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: onTube(start, startWidth))
        path.line(to: onTube(end, endWidth))
        path.line(to: onTube(end, -endWidth))
        path.line(to: onTube(start, -startWidth))
        path.close()
        path.lineJoinStyle = .round
        path.lineWidth = 0.9 * scale
        return path
    }

    color.setFill()
    color.setStroke()
    for part in [
        segment(from: -9.6, to: -7.3, startWidth: 0.75, endWidth: 0.75),   // eyepiece
        segment(from: -6.1, to: 6.0, startWidth: 1.75, endWidth: 2.55),    // tube
        segment(from: 7.3, to: 8.9, startWidth: 3.25, endWidth: 3.45),     // front ring
    ] {
        part.fill()
        part.stroke()
    }

    let legs = NSBezierPath()
    let joint = point(11.2, 10.7)
    for foot in [point(6.0, 1.7), point(11.2, 2.9), point(16.4, 1.7)] {
        legs.move(to: joint)
        legs.line(to: foot)
    }
    legs.lineWidth = 1.75 * scale
    legs.lineCapStyle = .round
    legs.lineJoinStyle = .round
    legs.stroke()
}

/// A four-pointed star.
func star(at center: NSPoint, radius: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let waist = radius * 0.16
    for step in 0..<8 {
        let angle = CGFloat(step) * .pi / 4
        let length = step.isMultiple(of: 2) ? radius : waist
        let point = NSPoint(x: center.x + cos(angle) * length, y: center.y + sin(angle) * length)
        if step == 0 { path.move(to: point) } else { path.line(to: point) }
    }
    path.close()
    return path
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

    NSGraphicsContext.saveGraphicsState()
    let drop = NSShadow()
    drop.shadowColor = NSColor.black.withAlphaComponent(0.28)
    drop.shadowBlurRadius = s * 0.022
    drop.shadowOffset = NSSize(width: 0, height: -s * 0.012)
    drop.set()
    NSColor.black.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.10, green: 0.13, blue: 0.47, alpha: 1), 0),
        (NSColor(srgbRed: 0.17, green: 0.33, blue: 0.86, alpha: 1), 0.48),
        (NSColor(srgbRed: 0.36, green: 0.74, blue: 1.0, alpha: 1), 1)
    )!.draw(in: body, angle: -90)

    func place(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
        NSPoint(x: body.minX + x * body.width, y: body.minY + y * body.height)
    }
    let target = place(0.77, 0.79)
    NSGradient(colorsAndLocations:
        (NSColor(srgbRed: 0.75, green: 0.86, blue: 1, alpha: 0.50), 0),
        (NSColor(srgbRed: 0.75, green: 0.86, blue: 1, alpha: 0.16), 0.38),
        (NSColor(srgbRed: 0.75, green: 0.86, blue: 1, alpha: 0), 1)
    )!.draw(fromCenter: target, radius: 0, toCenter: target, radius: body.width * 0.40, options: [])
    NSColor.white.setFill()
    star(at: target, radius: body.width * 0.085).fill()
    if px >= 128 {
        for (x, y, radius, alpha) in [
            (0.17, 0.83, 0.030, 0.85), (0.40, 0.90, 0.016, 0.7), (0.56, 0.74, 0.012, 0.55),
            (0.13, 0.60, 0.014, 0.6), (0.90, 0.56, 0.018, 0.7), (0.30, 0.70, 0.009, 0.5),
            (0.62, 0.90, 0.010, 0.55), (0.88, 0.90, 0.011, 0.5),
        ] as [(CGFloat, CGFloat, CGFloat, CGFloat)] {
            NSColor.white.withAlphaComponent(alpha).setFill()
            if radius > 0.015 {
                star(at: place(x, y), radius: body.width * radius * 1.5).fill()
            } else {
                let r = body.width * radius * 0.55
                let center = place(x, y)
                NSBezierPath(ovalIn: NSRect(x: center.x - r, y: center.y - r, width: 2 * r, height: 2 * r)).fill()
            }
        }
    }

    let side = body.width * 0.70
    let lift = NSShadow()
    lift.shadowColor = NSColor(srgbRed: 0.03, green: 0.06, blue: 0.30, alpha: 0.45)
    lift.shadowBlurRadius = s * 0.03
    lift.shadowOffset = NSSize(width: 0, height: -s * 0.014)
    lift.set()
    // One layer, so the shadow falls from the whole telescope and not from each stroke onto the next.
    let cg = NSGraphicsContext.current!.cgContext
    cg.beginTransparencyLayer(auxiliaryInfo: nil)
    drawTelescope(
        in: NSRect(x: body.midX - side * 0.53, y: body.minY + body.height * 0.105, width: side, height: side),
        color: .white
    )
    cg.endTransparencyLayer()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    shape.addClip()
    let edge = NSBezierPath(roundedRect: body.insetBy(dx: s * 0.004, dy: s * 0.004), xRadius: s * 181 / 1024, yRadius: s * 181 / 1024)
    edge.lineWidth = s * 0.008
    NSGradient(colors: [NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0), NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.30)])!
        .draw(in: edge.strokedOutline(), angle: 90)
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

extension NSBezierPath {
    func strokedOutline() -> NSBezierPath {
        let cgPath = CGMutablePath()
        var points = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<elementCount {
            switch element(at: index, associatedPoints: &points) {
            case .moveTo: cgPath.move(to: points[0])
            case .lineTo: cgPath.addLine(to: points[0])
            case .curveTo, .cubicCurveTo: cgPath.addCurve(to: points[2], control1: points[0], control2: points[1])
            case .quadraticCurveTo: cgPath.addQuadCurve(to: points[1], control: points[0])
            case .closePath: cgPath.closeSubpath()
            @unknown default: break
            }
        }
        let stroked = cgPath.copy(strokingWithWidth: lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
        let result = NSBezierPath()
        stroked.applyWithBlock { element in
            let p = element.pointee.points
            switch element.pointee.type {
            case .moveToPoint: result.move(to: p[0])
            case .addLineToPoint: result.line(to: p[0])
            case .addQuadCurveToPoint: result.curve(to: p[1], controlPoint: p[0])
            case .addCurveToPoint: result.curve(to: p[2], controlPoint1: p[0], controlPoint2: p[1])
            case .closeSubpath: result.close()
            @unknown default: break
            }
        }
        return result
    }
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
drawTelescope(in: mediaBox, color: .white)
NSGraphicsContext.restoreGraphicsState()
context.endPDFPage()
context.closePDF()
try (pdf as Data).write(to: URL(fileURLWithPath: "Resources/Telescope.pdf"))
