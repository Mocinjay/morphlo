import AppKit

/// The Morphlo mark: a butterfly ("metamorph") — files transform.
enum MorphloIcon {
    /// Butterfly wings + body in an 18×18 box, stroked.
    static func butterfly() -> (wings: NSBezierPath, body: NSBezierPath) {
        let left = NSBezierPath()
        left.move(to: NSPoint(x: 9, y: 9))
        left.curve(to: NSPoint(x: 2, y: 15), controlPoint1: NSPoint(x: 7, y: 13), controlPoint2: NSPoint(x: 3, y: 16.5))
        left.curve(to: NSPoint(x: 9, y: 9), controlPoint1: NSPoint(x: 0.5, y: 12), controlPoint2: NSPoint(x: 5, y: 9.5))
        left.move(to: NSPoint(x: 9, y: 9))
        left.curve(to: NSPoint(x: 3.5, y: 3), controlPoint1: NSPoint(x: 6, y: 7.5), controlPoint2: NSPoint(x: 2, y: 5))
        left.curve(to: NSPoint(x: 9, y: 9), controlPoint1: NSPoint(x: 5.5, y: 1.5), controlPoint2: NSPoint(x: 8.5, y: 5))
        let wings = left.copy() as! NSBezierPath
        let right = left.copy() as! NSBezierPath
        var mirror = AffineTransform(translationByX: 18, byY: 0)
        mirror.scale(x: -1, y: 1)
        right.transform(using: mirror)
        wings.append(right)
        let body = NSBezierPath()
        body.move(to: NSPoint(x: 9, y: 4)); body.line(to: NSPoint(x: 9, y: 13))
        return (wings, body)
    }

    /// Template image for the menu bar: macOS tints it for light/dark bars and highlight.
    static func menuBar() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let (wings, body) = butterfly()
            NSColor.black.setStroke()
            for (p, w) in [(wings, 1.6), (body, 1.4)] as [(NSBezierPath, CGFloat)] {
                p.lineWidth = w; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Morphlo"
        return image
    }
}
