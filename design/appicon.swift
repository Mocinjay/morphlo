import AppKit
// Renders the 1024px Kyvert app icon: violet squircle, white K-arrow.
let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
    let inset: CGFloat = 100            // Apple's icon grid: ~824pt artwork in a 1024 canvas
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let shape = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 28; shadow.shadowOffset = NSSize(width: 0, height: -12); shadow.set()
    NSColor.black.setFill(); shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(colors: [NSColor(red: 0.56, green: 0.36, blue: 1.0, alpha: 1),     // violet
                        NSColor(red: 0.27, green: 0.20, blue: 0.86, alpha: 1),     // indigo
                        NSColor(red: 0.12, green: 0.10, blue: 0.42, alpha: 1)])!   // deep navy
        .draw(in: shape, angle: -70)
    // soft top highlight
    NSGradient(starting: NSColor.white.withAlphaComponent(0.22), ending: NSColor.white.withAlphaComponent(0))!
        .draw(in: NSBezierPath(roundedRect: NSRect(x: tile.minX, y: tile.midY, width: tile.width, height: tile.height / 2), xRadius: 185, yRadius: 185), angle: -90)
    // Butterfly, scaled from the 18pt glyph
    func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: tile.minX + tile.width * 0.13 + x / 18 * tile.width * 0.74, y: tile.minY + tile.height * 0.13 + y / 18 * tile.height * 0.74) }
    let k = NSBezierPath()
    func wing(_ m: CGFloat) {
        func q(_ x: CGFloat, _ y: CGFloat) -> NSPoint { pt(m < 0 ? 18 - x : x, y) }
        k.move(to: q(9, 9))
        k.curve(to: q(2, 15), controlPoint1: q(7, 13), controlPoint2: q(3, 16.5))
        k.curve(to: q(9, 9), controlPoint1: q(0.5, 12), controlPoint2: q(5, 9.5))
        k.move(to: q(9, 9))
        k.curve(to: q(3.5, 3), controlPoint1: q(6, 7.5), controlPoint2: q(2, 5))
        k.curve(to: q(9, 9), controlPoint1: q(5.5, 1.5), controlPoint2: q(8.5, 5))
    }
    wing(1); wing(-1)
    k.move(to: pt(9, 4)); k.line(to: pt(9, 13))
    k.lineWidth = 1.6 / 18 * tile.width * 0.74 * 1.1
    k.lineCapStyle = .round; k.lineJoinStyle = .round
    NSGraphicsContext.saveGraphicsState()
    let ks = NSShadow(); ks.shadowColor = NSColor.black.withAlphaComponent(0.25); ks.shadowBlurRadius = 18; ks.shadowOffset = NSSize(width: 0, height: -8); ks.set()
    NSColor.white.setStroke(); k.stroke()
    NSGraphicsContext.restoreGraphicsState()
    return true
}
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
img.draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
