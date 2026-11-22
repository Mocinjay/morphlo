import AppKit

// Ten menu-bar concepts for Kyvert. Each draws into an 18x18pt box (origin bottom-left) in `c`.
typealias Draw = (NSColor) -> Void
let LW: CGFloat = 1.6

func stroke(_ p: NSBezierPath, _ c: NSColor, _ w: CGFloat = LW) {
    p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; c.setStroke(); p.stroke()
}
func head(_ tip: NSPoint, _ angle: CGFloat, _ s: CGFloat) -> NSBezierPath {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: tip.x + cos(angle + .pi * 0.78) * s, y: tip.y + sin(angle + .pi * 0.78) * s))
    p.line(to: tip)
    p.line(to: NSPoint(x: tip.x + cos(angle - .pi * 0.78) * s, y: tip.y + sin(angle - .pi * 0.78) * s))
    return p
}
func sparkle(_ c: NSPoint, _ r: CGFloat, _ col: NSColor) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: c.x, y: c.y + r))
    p.curve(to: NSPoint(x: c.x + r, y: c.y), controlPoint1: NSPoint(x: c.x + r * 0.15, y: c.y + r * 0.15), controlPoint2: NSPoint(x: c.x + r * 0.15, y: c.y + r * 0.15))
    p.curve(to: NSPoint(x: c.x, y: c.y - r), controlPoint1: NSPoint(x: c.x + r * 0.15, y: c.y - r * 0.15), controlPoint2: NSPoint(x: c.x + r * 0.15, y: c.y - r * 0.15))
    p.curve(to: NSPoint(x: c.x - r, y: c.y), controlPoint1: NSPoint(x: c.x - r * 0.15, y: c.y - r * 0.15), controlPoint2: NSPoint(x: c.x - r * 0.15, y: c.y - r * 0.15))
    p.curve(to: NSPoint(x: c.x, y: c.y + r), controlPoint1: NSPoint(x: c.x - r * 0.15, y: c.y + r * 0.15), controlPoint2: NSPoint(x: c.x - r * 0.15, y: c.y + r * 0.15))
    p.close(); col.setFill(); p.fill()
}

let concepts: [(String, String, Draw)] = [
    ("1 Shapeshift", "half square, half circle: a file mid-transformation", { c in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 9, y: 2.5)); p.line(to: NSPoint(x: 4, y: 2.5))
        p.appendArc(withCenter: NSPoint(x: 4, y: 4.5), radius: 2, startAngle: 270, endAngle: 180, clockwise: true)
        p.line(to: NSPoint(x: 2, y: 13.5))
        p.appendArc(withCenter: NSPoint(x: 4, y: 13.5), radius: 2, startAngle: 180, endAngle: 90, clockwise: true)
        p.line(to: NSPoint(x: 9, y: 15.5))
        p.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 6.5, startAngle: 90, endAngle: -90, clockwise: true)
        stroke(p, c)
        let d = NSBezierPath(); d.move(to: NSPoint(x: 9, y: 4.6)); d.line(to: NSPoint(x: 9, y: 13.4)); stroke(d, c, 1.1)
    }),
    ("2 Prism", "one file in, the right format out (like light through a prism)", { c in
        let t = NSBezierPath()
        t.move(to: NSPoint(x: 9, y: 15)); t.line(to: NSPoint(x: 14.5, y: 4.5)); t.line(to: NSPoint(x: 3.5, y: 4.5)); t.close()
        stroke(t, c)
        let a = NSBezierPath(); a.move(to: NSPoint(x: 0.8, y: 8.2)); a.line(to: NSPoint(x: 6.6, y: 10)); stroke(a, c, 1.3)
        for (y, w) in [(12.0, 1.3), (9.6, 1.3), (7.2, 1.3)] as [(CGFloat, CGFloat)] {
            let r = NSBezierPath(); r.move(to: NSPoint(x: 11.6, y: 10)); r.line(to: NSPoint(x: 17.2, y: y)); stroke(r, c, w)
        }
    }),
    ("3 Magic drop", "a droplet with a sparkle: drop it, it's fixed", { c in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 8, y: 16.2))
        p.curve(to: NSPoint(x: 3, y: 7), controlPoint1: NSPoint(x: 6.5, y: 13), controlPoint2: NSPoint(x: 3, y: 10.5))
        p.appendArc(withCenter: NSPoint(x: 8, y: 7), radius: 5, startAngle: 180, endAngle: 0, clockwise: false)
        p.curve(to: NSPoint(x: 8, y: 16.2), controlPoint1: NSPoint(x: 13, y: 10.5), controlPoint2: NSPoint(x: 9.5, y: 13))
        stroke(p, c)
        sparkle(NSPoint(x: 15, y: 14.5), 2.6, c)
        sparkle(NSPoint(x: 8, y: 7), 2.4, c)
    }),
    ("4 Metamorph", "a butterfly — the file transforms", { c in
        let l = NSBezierPath()
        l.move(to: NSPoint(x: 9, y: 9))
        l.curve(to: NSPoint(x: 2, y: 15), controlPoint1: NSPoint(x: 7, y: 13), controlPoint2: NSPoint(x: 3, y: 16.5))
        l.curve(to: NSPoint(x: 9, y: 9), controlPoint1: NSPoint(x: 0.5, y: 12), controlPoint2: NSPoint(x: 5, y: 9.5))
        l.move(to: NSPoint(x: 9, y: 9))
        l.curve(to: NSPoint(x: 3.5, y: 3), controlPoint1: NSPoint(x: 6, y: 7.5), controlPoint2: NSPoint(x: 2, y: 5))
        l.curve(to: NSPoint(x: 9, y: 9), controlPoint1: NSPoint(x: 5.5, y: 1.5), controlPoint2: NSPoint(x: 8.5, y: 5))
        let r = l.copy() as! NSBezierPath
        let flip = AffineTransform(translationByX: 18, byY: 0); var f = flip; f.scale(x: -1, y: 1)
        r.transform(using: f)
        stroke(l, c); stroke(r, c)
        let b = NSBezierPath(); b.move(to: NSPoint(x: 9, y: 4)); b.line(to: NSPoint(x: 9, y: 13)); stroke(b, c, 1.4)
    }),
    ("5 Flip file", "a page whose folded corner is an arrow", { c in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 10.5, y: 16)); p.line(to: NSPoint(x: 5, y: 16))
        p.appendArc(withCenter: NSPoint(x: 5, y: 14), radius: 2, startAngle: 90, endAngle: 180, clockwise: false)
        p.line(to: NSPoint(x: 3, y: 4))
        p.appendArc(withCenter: NSPoint(x: 5, y: 4), radius: 2, startAngle: 180, endAngle: 270, clockwise: false)
        p.line(to: NSPoint(x: 13, y: 2))
        p.appendArc(withCenter: NSPoint(x: 13, y: 4), radius: 2, startAngle: 270, endAngle: 360, clockwise: false)
        p.line(to: NSPoint(x: 15, y: 10.5))
        stroke(p, c)
        let a = NSBezierPath()
        a.move(to: NSPoint(x: 9.5, y: 9.5)); a.curve(to: NSPoint(x: 15.2, y: 16), controlPoint1: NSPoint(x: 10, y: 13), controlPoint2: NSPoint(x: 12.5, y: 15.5))
        stroke(a, c)
        stroke(head(NSPoint(x: 15.6, y: 16.1), 0.2, 3.2), c)
    }),
    ("6 Swap tiles", "two cards trading places", { c in
        stroke(NSBezierPath(roundedRect: NSRect(x: 1.8, y: 1.8, width: 8, height: 8), xRadius: 2.3, yRadius: 2.3), c)
        stroke(NSBezierPath(roundedRect: NSRect(x: 8.2, y: 8.2, width: 8, height: 8), xRadius: 2.3, yRadius: 2.3), c)
        let a = NSBezierPath(); a.move(to: NSPoint(x: 3.5, y: 13)); a.curve(to: NSPoint(x: 6, y: 15.8), controlPoint1: NSPoint(x: 3.5, y: 14.8), controlPoint2: NSPoint(x: 4.5, y: 15.8))
        stroke(a, c, 1.3); stroke(head(NSPoint(x: 6.4, y: 15.8), 0, 2.2), c, 1.3)
        let b = NSBezierPath(); b.move(to: NSPoint(x: 14.5, y: 5)); b.curve(to: NSPoint(x: 12, y: 2.2), controlPoint1: NSPoint(x: 14.5, y: 3.2), controlPoint2: NSPoint(x: 13.5, y: 2.2))
        stroke(b, c, 1.3); stroke(head(NSPoint(x: 11.6, y: 2.2), .pi, 2.2), c, 1.3)
    }),
    ("7 Funnel", "anything in, one clean format out", { c in
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 2, y: 15)); p.line(to: NSPoint(x: 16, y: 15)); p.line(to: NSPoint(x: 10.5, y: 8.5))
        p.line(to: NSPoint(x: 10.5, y: 3)); p.line(to: NSPoint(x: 7.5, y: 4.5)); p.line(to: NSPoint(x: 7.5, y: 8.5)); p.close()
        stroke(p, c)
        sparkle(NSPoint(x: 9, y: 12.3), 1.6, c)
    }),
    ("8 Orbit", "a file with a spark orbiting it — always working in the background", { c in
        stroke(NSBezierPath(roundedRect: NSRect(x: 5.2, y: 5.2, width: 7.6, height: 7.6), xRadius: 2, yRadius: 2), c)
        let o = NSBezierPath(); o.appendArc(withCenter: NSPoint(x: 9, y: 9), radius: 7.6, startAngle: 120, endAngle: 60, clockwise: false)
        stroke(o, c, 1.2)
        let dot = NSBezierPath(ovalIn: NSRect(x: 11.6, y: 14.4, width: 3.2, height: 3.2)); c.setFill(); dot.fill()
    }),
    ("9 Loop", "an infinity loop with an arrow — continuous, automatic", { c in
        // Lemniscate of Bernoulli, sampled.
        let p = NSBezierPath(); let A: CGFloat = 7.4
        for i in 0...120 {
            let t = CGFloat(i) / 120 * 2 * .pi
            let d = 1 + sin(t) * sin(t)
            let pt = NSPoint(x: 9 + A * cos(t) / d, y: 9 + A * sin(t) * cos(t) / d * 1.25)
            if i == 0 { p.move(to: pt) } else { p.line(to: pt) }
        }
        p.close(); stroke(p, c)
        // arrowhead on the right lobe, travelling up
        let t: CGFloat = 0.55, d = 1 + sin(t) * sin(t)
        let tip = NSPoint(x: 9 + A * cos(t) / d, y: 9 + A * sin(t) * cos(t) / d * 1.25)
        stroke(head(tip, 2.15, 2.8), c, 1.5)
    }),
    ("10 Exchange", "two arrows forming an X — format exchange, also a playful 'x' for 'vert'", { c in
        let a = NSBezierPath(); a.move(to: NSPoint(x: 3, y: 3)); a.line(to: NSPoint(x: 14.5, y: 14.5)); stroke(a, c)
        stroke(head(NSPoint(x: 15, y: 15), .pi / 4, 3.6), c)
        let b = NSBezierPath(); b.move(to: NSPoint(x: 15, y: 3)); b.line(to: NSPoint(x: 10.5, y: 7.5)); b.move(to: NSPoint(x: 7.5, y: 10.5)); b.line(to: NSPoint(x: 3.5, y: 14.5)); stroke(b, c)
        stroke(head(NSPoint(x: 3, y: 15), .pi * 3 / 4, 3.6), c)
    }),
]

func img(_ d: @escaping Draw, scale: CGFloat, color: NSColor) -> NSImage {
    NSImage(size: NSSize(width: 18 * scale, height: 18 * scale), flipped: false) { _ in
        let t = NSAffineTransform(); t.scale(by: scale); t.concat(); d(color); return true
    }
}

let cols = 2, cellW: CGFloat = 640, cellH: CGFloat = 150
let rows = (concepts.count + cols - 1) / cols
let sheet = NSImage(size: NSSize(width: cellW * CGFloat(cols), height: cellH * CGFloat(rows)), flipped: true) { _ in
    NSColor(white: 0.97, alpha: 1).setFill(); NSRect(x: 0, y: 0, width: cellW * CGFloat(cols), height: cellH * CGFloat(rows)).fill()
    for (i, (name, blurb, d)) in concepts.enumerated() {
        let x = CGFloat(i % cols) * cellW, y = CGFloat(i / cols) * cellH
        img(d, scale: 6, color: .black).draw(in: NSRect(x: x + 12, y: y + 18, width: 108, height: 108))
        (name as NSString).draw(at: NSPoint(x: x + 135, y: y + 14), withAttributes: [.font: NSFont.systemFont(ofSize: 19, weight: .bold)])
        (blurb as NSString).draw(in: NSRect(x: x + 135, y: y + 40, width: 480, height: 40), withAttributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.darkGray])
        NSColor(red: 0.07, green: 0.09, blue: 0.14, alpha: 1).setFill(); NSRect(x: x + 135, y: y + 88, width: 225, height: 46).fill()
        img(d, scale: 2, color: .white).draw(in: NSRect(x: x + 152, y: y + 93, width: 36, height: 36))
        if let wifi = NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 30, weight: .regular)) {
            let w = NSImage(size: wifi.size, flipped: false) { r in wifi.draw(in: r); NSColor.white.set(); r.fill(using: .sourceAtop); return true }
            w.draw(in: NSRect(x: x + 215, y: y + 96, width: 36, height: 30))
        }
        NSColor(white: 0.88, alpha: 1).setFill(); NSRect(x: x + 375, y: y + 88, width: 225, height: 46).fill()
        img(d, scale: 2, color: .black).draw(in: NSRect(x: x + 392, y: y + 93, width: 36, height: 36))
        NSImage(systemSymbolName: "wifi", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 30, weight: .regular))?.draw(in: NSRect(x: x + 455, y: y + 96, width: 36, height: 30))
    }
    return true
}
let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
print("ok")
