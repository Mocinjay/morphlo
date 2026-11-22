import AppKit

// Each glyph draws into an 18x18 point box (origin bottom-left), black on clear.
typealias Glyph = (CGFloat) -> NSBezierPath  // arg: line width

func arrowHead(at tip: NSPoint, angle: CGFloat, size: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    let a1 = angle + .pi * 0.78, a2 = angle - .pi * 0.78
    p.move(to: NSPoint(x: tip.x + cos(a1) * size, y: tip.y + sin(a1) * size))
    p.line(to: tip)
    p.line(to: NSPoint(x: tip.x + cos(a2) * size, y: tip.y + sin(a2) * size))
    return p
}

let glyphs: [(String, Glyph)] = [
    ("A2  K-arrow, refined", { w in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 4.2, y: 2.4)); p.line(to: NSPoint(x: 4.2, y: 15.6))
        p.move(to: NSPoint(x: 4.2, y: 8.2)); p.line(to: NSPoint(x: 13.2, y: 14.6))
        p.append(arrowHead(at: NSPoint(x: 13.6, y: 14.9), angle: atan2(6.4, 9), size: 4.2))
        p.move(to: NSPoint(x: 7.8, y: 10.7)); p.line(to: NSPoint(x: 13.4, y: 2.4))
        return p
    }),
    ("C2  K-arrow in card (thicker)", { w in
        let p = NSBezierPath(roundedRect: NSRect(x: 1.6, y: 1.6, width: 14.8, height: 14.8), xRadius: 4.2, yRadius: 4.2)
        p.move(to: NSPoint(x: 6.4, y: 4.8)); p.line(to: NSPoint(x: 6.4, y: 13.2))
        p.move(to: NSPoint(x: 6.4, y: 8.8)); p.line(to: NSPoint(x: 11.6, y: 12.9))
        p.append(arrowHead(at: NSPoint(x: 11.9, y: 13.1), angle: atan2(4.1, 5.2), size: 3.0))
        p.move(to: NSPoint(x: 8.4, y: 10.4)); p.line(to: NSPoint(x: 11.8, y: 4.8))
        return p
    }),
]

func render(_ g: @escaping Glyph, scale: CGFloat, color: NSColor, w: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: 18 * scale, height: 18 * scale), flipped: false) { _ in
        let t = NSAffineTransform(); t.scale(by: scale); t.concat()
        let path = g(w)
        path.lineWidth = w; path.lineCapStyle = .round; path.lineJoinStyle = .round
        color.setStroke(); path.stroke()
        return true
    }
}

// Contact sheet: for each glyph, large preview + actual size on dark & light menu bars (at 2x).
let rowH: CGFloat = 130, W: CGFloat = 900
let sheet = NSImage(size: NSSize(width: W, height: rowH * CGFloat(glyphs.count)), flipped: true) { _ in
    for (i, (name, g)) in glyphs.enumerated() {
        let y = CGFloat(i) * rowH
        NSColor(white: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: y, width: W, height: rowH).fill()
        render(g, scale: 6, color: .black, w: 1.75).draw(in: NSRect(x: 10, y: y + 11, width: 108, height: 108))
        (name as NSString).draw(at: NSPoint(x: 135, y: y + 12), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold)])
        // dark bar
        NSColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1).setFill(); NSRect(x: 135, y: y + 45, width: 340, height: 48).fill()
        for (j, s) in ["photo.on.rectangle.angled", "magnifyingglass", "wifi"].enumerated() {
            if let im = NSImage(systemSymbolName: s, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 30, weight: .regular)) {
                let tinted = NSImage(size: im.size, flipped: false) { r in im.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
                tinted.draw(in: NSRect(x: 230 + CGFloat(j) * 80, y: y + 52, width: 36, height: 34))
            }
        }
        render(g, scale: 2, color: .white, w: 1.75).draw(in: NSRect(x: 160, y: y + 51, width: 36, height: 36))
        // light bar
        NSColor(white: 0.88, alpha: 1).setFill(); NSRect(x: 500, y: y + 45, width: 340, height: 48).fill()
        render(g, scale: 2, color: .black, w: 1.75).draw(in: NSRect(x: 525, y: y + 51, width: 36, height: 36))
        for (j, s) in ["photo.on.rectangle.angled", "magnifyingglass", "wifi"].enumerated() {
            if let im = NSImage(systemSymbolName: s, accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 30, weight: .regular)) {
                im.draw(in: NSRect(x: 595 + CGFloat(j) * 80, y: y + 52, width: 36, height: 34))
            }
        }
    }
    return true
}
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")

// Filled tile variant: solid rounded square with the K-arrow knocked out.
func filledTile(scale: CGFloat, color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 18 * scale, height: 18 * scale), flipped: false) { r in
        let t = NSAffineTransform(); t.scale(by: scale); t.concat()
        color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 1.5, y: 1.5, width: 15, height: 15), xRadius: 4.2, yRadius: 4.2).fill()
        let k = NSBezierPath()
        k.move(to: NSPoint(x: 6.3, y: 4.6)); k.line(to: NSPoint(x: 6.3, y: 13.4))
        k.move(to: NSPoint(x: 6.3, y: 8.8)); k.line(to: NSPoint(x: 11.8, y: 13.0))
        k.append(arrowHead(at: NSPoint(x: 12.1, y: 13.2), angle: atan2(4.2, 5.5), size: 3.1))
        k.move(to: NSPoint(x: 8.4, y: 10.4)); k.line(to: NSPoint(x: 12.0, y: 4.6))
        k.lineWidth = 1.7; k.lineCapStyle = .round; k.lineJoinStyle = .round
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.setStroke(); k.stroke()
        return true
    }
}
let tileSheet = NSImage(size: NSSize(width: 900, height: 130), flipped: true) { _ in
    NSColor(white: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: 900, height: 130).fill()
    filledTile(scale: 6, color: .black).draw(in: NSRect(x: 10, y: 11, width: 108, height: 108))
    ("F  solid tile, K-arrow cut out" as NSString).draw(at: NSPoint(x: 135, y: 12), withAttributes: [.font: NSFont.systemFont(ofSize: 18, weight: .semibold)])
    NSColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1).setFill(); NSRect(x: 135, y: 45, width: 340, height: 48).fill()
    filledTile(scale: 2, color: .white).draw(in: NSRect(x: 160, y: 51, width: 36, height: 36))
    NSColor(white: 0.88, alpha: 1).setFill(); NSRect(x: 500, y: 45, width: 340, height: 48).fill()
    filledTile(scale: 2, color: .black).draw(in: NSRect(x: 525, y: 51, width: 36, height: 36))
    return true
}
let rep2 = NSBitmapImageRep(data: tileSheet.tiffRepresentation!)!
try! rep2.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
