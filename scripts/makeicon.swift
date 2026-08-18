import AppKit

// Renders the Objective app icon: a white target reticle on a violet
// gradient squircle. Writes a 1024x1024 PNG to the path in argv[1].

let out = CommandLine.arguments[1]
let size: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size), pixelsHigh: Int(size),
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let inset: CGFloat = 100
let cardRect = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let card = NSBezierPath(roundedRect: cardRect, xRadius: 185, yRadius: 185)

// Soft drop shadow behind the card.
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowBlurRadius = 24
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(calibratedRed: 0.16, green: 0.13, blue: 0.36, alpha: 1).setFill()
card.fill()
NSShadow().set()

// Gradient fill, dark at the bottom, violet at the top.
card.setClip()
NSGradient(colors: [
    NSColor(calibratedRed: 0.13, green: 0.10, blue: 0.32, alpha: 1),
    NSColor(calibratedRed: 0.44, green: 0.28, blue: 0.80, alpha: 1),
])!.draw(in: cardRect, angle: 90)

// Subtle top glass highlight.
NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.0),
    NSColor.white.withAlphaComponent(0.18),
])!.draw(
    in: NSRect(x: cardRect.minX, y: cardRect.midY, width: cardRect.width, height: cardRect.height / 2),
    angle: 90
)

let center = NSPoint(x: size / 2, y: size / 2)

func ring(radius: CGFloat, lineWidth: CGFloat, alpha: CGFloat) {
    let r = NSRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    let p = NSBezierPath(ovalIn: r)
    p.lineWidth = lineWidth
    NSColor.white.withAlphaComponent(alpha).setStroke()
    p.stroke()
}

ring(radius: 268, lineWidth: 36, alpha: 0.96)
ring(radius: 168, lineWidth: 30, alpha: 0.75)

// Center dot.
let dotR: CGFloat = 60
NSColor.white.setFill()
NSBezierPath(ovalIn: NSRect(x: center.x - dotR, y: center.y - dotR, width: dotR * 2, height: dotR * 2)).fill()

// Four crosshair ticks that cross the outer ring.
NSColor.white.withAlphaComponent(0.96).setFill()
let tickW: CGFloat = 36
let tickFrom: CGFloat = 224
let tickTo: CGFloat = 352
for (dx, dy) in [(0, 1), (0, -1), (1, 0), (-1, 0)] {
    let rect: NSRect
    if dx == 0 {
        let yLow = dy > 0 ? center.y + tickFrom : center.y - tickTo
        rect = NSRect(x: center.x - tickW / 2, y: yLow, width: tickW, height: tickTo - tickFrom)
    } else {
        let xLow = dx > 0 ? center.x + tickFrom : center.x - tickTo
        rect = NSRect(x: xLow, y: center.y - tickW / 2, width: tickTo - tickFrom, height: tickW)
    }
    NSBezierPath(roundedRect: rect, xRadius: tickW / 2, yRadius: tickW / 2).fill()
}

NSGraphicsContext.restoreGraphicsState()

let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
