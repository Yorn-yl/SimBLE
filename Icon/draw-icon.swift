// Draws the SimBLE app icon: a happy little phone with a Bluetooth antenna, sending hearts.
// Usage: swift Icon/draw-icon.swift <output.png> [size]   (make-icon.sh builds AppIcon.icns from it)
// Laid out on Apple's macOS icon grid: 1024 canvas, 824 rounded-square body, shadow in the margin.

import AppKit

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: draw-icon.swift <output.png> [size]")
    exit(1)
}
let size = CGFloat(arguments.count > 2 ? Double(arguments[2]) ?? 1024 : 1024)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func heart(center: CGPoint, size: CGFloat) -> NSBezierPath {
    let x = center.x, y = center.y, s = size
    let path = NSBezierPath()
    path.move(to: CGPoint(x: x, y: y - 0.42 * s))
    path.curve(to: CGPoint(x: x - 0.5 * s, y: y + 0.1 * s), controlPoint1: CGPoint(x: x - 0.18 * s, y: y - 0.24 * s),
               controlPoint2: CGPoint(x: x - 0.5 * s, y: y - 0.1 * s))
    path.appendArc(withCenter: CGPoint(x: x - 0.25 * s, y: y + 0.1 * s), radius: 0.25 * s, startAngle: 180, endAngle: 0, clockwise: true)
    path.appendArc(withCenter: CGPoint(x: x + 0.25 * s, y: y + 0.1 * s), radius: 0.25 * s, startAngle: 180, endAngle: 0, clockwise: true)
    path.curve(to: CGPoint(x: x, y: y - 0.42 * s), controlPoint1: CGPoint(x: x + 0.5 * s, y: y - 0.1 * s),
               controlPoint2: CGPoint(x: x + 0.18 * s, y: y - 0.24 * s))
    path.close()
    return path
}

func sparkle(center: CGPoint, radius: CGFloat) -> NSBezierPath {
    let x = center.x, y = center.y, r = radius, pinch = 0.14 * radius
    let path = NSBezierPath()
    path.move(to: CGPoint(x: x, y: y + r))
    path.curve(to: CGPoint(x: x + r, y: y), controlPoint1: CGPoint(x: x + pinch, y: y + pinch), controlPoint2: CGPoint(x: x + pinch, y: y + pinch))
    path.curve(to: CGPoint(x: x, y: y - r), controlPoint1: CGPoint(x: x + pinch, y: y - pinch), controlPoint2: CGPoint(x: x + pinch, y: y - pinch))
    path.curve(to: CGPoint(x: x - r, y: y), controlPoint1: CGPoint(x: x - pinch, y: y - pinch), controlPoint2: CGPoint(x: x - pinch, y: y - pinch))
    path.curve(to: CGPoint(x: x, y: y + r), controlPoint1: CGPoint(x: x - pinch, y: y + pinch), controlPoint2: CGPoint(x: x - pinch, y: y + pinch))
    path.close()
    return path
}

let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                              samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.scaleBy(x: size / 1024, y: size / 1024)

// Radial highlights end at 0.7: NSGradient spreads them to the corners of the path's bounds, and a circle
// reaches its edge at 1/√2 of that.

// Soft sky-to-lavender body with the grid's drop shadow.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: color(0x3A2A6B, 0.3).cgColor)
color(0xB9C8FF).setFill()
bodyPath.fill()
context.restoreGState()
context.saveGState()
bodyPath.addClip()
NSGradient(colors: [color(0xA9E2FF), color(0xC3CCFF), color(0xE4C6FF)], atLocations: [0, 0.55, 1], colorSpace: .sRGB)!
    .draw(in: body, angle: -90)
NSGradient(colors: [color(0xFFFFFF, 0.45), color(0xFFFFFF, 0), color(0xFFFFFF, 0)], atLocations: [0, 0.7, 1], colorSpace: .sRGB)!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: 40, y: 560, width: 560, height: 560)), relativeCenterPosition: .zero)

// Hearts and sparkles floating around.
color(0xFF7FA8).setFill()
heart(center: CGPoint(x: 780, y: 610), size: 92).fill()
color(0xFF9FC0, 0.85).setFill()
heart(center: CGPoint(x: 846, y: 745), size: 56).fill()
color(0xFFB3CF, 0.9).setFill()
heart(center: CGPoint(x: 232, y: 420), size: 62).fill()
color(0xFFFFFF).setFill()
sparkle(center: CGPoint(x: 245, y: 740), radius: 46).fill()
sparkle(center: CGPoint(x: 800, y: 395), radius: 30).fill()
sparkle(center: CGPoint(x: 330, y: 845), radius: 22).fill()
context.restoreGState()

// Ground shadow under the character.
color(0x6A58C8, 0.18).setFill()
NSBezierPath(ovalIn: NSRect(x: 352, y: 160, width: 320, height: 52)).fill()

// The character, tilted a little for a playful pose.
context.saveGState()
context.translateBy(x: 505, y: 440)
context.rotate(by: 6 * .pi / 180)
context.translateBy(x: -505, y: -440)

// Antenna: a curly sprout ending in a Bluetooth bubble.
let stalk = NSBezierPath()
stalk.move(to: CGPoint(x: 505, y: 690))
stalk.curve(to: CGPoint(x: 548, y: 790), controlPoint1: CGPoint(x: 490, y: 740), controlPoint2: CGPoint(x: 560, y: 745))
stalk.lineWidth = 26
stalk.lineCapStyle = .round
color(0xFFFFFF).setStroke()
stalk.stroke()

let bubble = NSRect(x: 548 - 74, y: 800 - 74 + 20, width: 148, height: 148)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: color(0x2E4DB8, 0.35).cgColor)
color(0xFFFFFF).setFill()
NSBezierPath(ovalIn: bubble.insetBy(dx: -12, dy: -12)).fill()
context.restoreGState()
NSGradient(colors: [color(0x5AB0FF), color(0x2F6BEA)])!.draw(in: NSBezierPath(ovalIn: bubble), angle: -90)
let rune = NSBezierPath()
let runeX = bubble.midX + 6, runeY = bubble.midY, unit: CGFloat = 50
rune.move(to: CGPoint(x: runeX - 0.7 * unit, y: runeY + 0.5 * unit))
rune.line(to: CGPoint(x: runeX + 0.62 * unit, y: runeY - 0.5 * unit))
rune.line(to: CGPoint(x: runeX, y: runeY - unit))
rune.line(to: CGPoint(x: runeX, y: runeY + unit))
rune.line(to: CGPoint(x: runeX + 0.62 * unit, y: runeY + 0.5 * unit))
rune.line(to: CGPoint(x: runeX - 0.7 * unit, y: runeY - 0.5 * unit))
rune.lineWidth = 17
rune.lineCapStyle = .round
rune.lineJoinStyle = .round
color(0xFFFFFF).setStroke()
rune.stroke()

// Chubby phone body.
let phone = NSRect(x: 505 - 190, y: 440 - 250, width: 380, height: 500)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -10), blur: 26, color: color(0x4B3A9E, 0.35).cgColor)
color(0xFFFFFF).setFill()
NSBezierPath(roundedRect: phone, xRadius: 120, yRadius: 120).fill()
context.restoreGState()
let screen = phone.insetBy(dx: 30, dy: 30)
let screenPath = NSBezierPath(roundedRect: screen, xRadius: 92, yRadius: 92)
NSGradient(colors: [color(0x8FD3FF), color(0x6FA8FF)])!.draw(in: screenPath, angle: -90)
context.saveGState()
screenPath.addClip()
NSGradient(colors: [color(0xFFFFFF, 0.35), color(0xFFFFFF, 0), color(0xFFFFFF, 0)], atLocations: [0, 0.7, 1], colorSpace: .sRGB)!
    .draw(in: NSBezierPath(ovalIn: NSRect(x: screen.minX - 70, y: screen.maxY - 200, width: 320, height: 320)), relativeCenterPosition: .zero)
context.restoreGState()

// Face: sparkly eyes, rosy cheeks and a smile.
for eyeX in [CGFloat(435), 575] {
    color(0x2B2A4A).setFill()
    NSBezierPath(ovalIn: NSRect(x: eyeX - 30, y: 440, width: 60, height: 76)).fill()
    color(0xFFFFFF).setFill()
    NSBezierPath(ovalIn: NSRect(x: eyeX - 4, y: 486, width: 24, height: 24)).fill()
    NSBezierPath(ovalIn: NSRect(x: eyeX - 18, y: 456, width: 11, height: 11)).fill()
}
color(0xFF7FA8, 0.75).setFill()
NSBezierPath(ovalIn: NSRect(x: 360, y: 400, width: 64, height: 34)).fill()
NSBezierPath(ovalIn: NSRect(x: 586, y: 400, width: 64, height: 34)).fill()
let smile = NSBezierPath()
smile.appendArc(withCenter: CGPoint(x: 505, y: 428), radius: 34, startAngle: 205, endAngle: 335, clockwise: false)
smile.lineWidth = 14
smile.lineCapStyle = .round
color(0x2B2A4A).setStroke()
smile.stroke()
context.restoreGState()

NSGraphicsContext.current = nil
try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[1]))
