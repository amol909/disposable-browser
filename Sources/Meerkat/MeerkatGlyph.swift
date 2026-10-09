import AppKit

/// The meerkat artwork, shared by the menu bar icon and `scripts/AppIcon` (the app icon).
/// Shapes use a 24-point square with a top-left origin, so callers draw in a flipped space.
/// This file depends only on AppKit, so the icon script can compile it on its own.
enum MeerkatGlyph {
    /// Fills the head (with eye and nose holes) and ears in the current color. The chin is at y = 19.
    static func fillHead() {
        let head = NSBezierPath()
        head.move(to: NSPoint(x: 7.6, y: 19))
        head.curve(to: NSPoint(x: 7.6, y: 10.1), controlPoint1: NSPoint(x: 7.1, y: 15.4), controlPoint2: NSPoint(x: 6.9, y: 12.4))
        head.curve(to: NSPoint(x: 12, y: 6.4), controlPoint1: NSPoint(x: 8.4, y: 7.7), controlPoint2: NSPoint(x: 10, y: 6.4))
        head.curve(to: NSPoint(x: 16.4, y: 10.1), controlPoint1: NSPoint(x: 14, y: 6.4), controlPoint2: NSPoint(x: 15.6, y: 7.7))
        head.curve(to: NSPoint(x: 16.4, y: 19), controlPoint1: NSPoint(x: 17.1, y: 12.4), controlPoint2: NSPoint(x: 16.9, y: 15.4))
        head.close()
        // Even-odd filling turns the eyes and nose, which lie inside the head, into holes.
        head.append(oval(x: 9.7, y: 11.7, rx: 1.6, ry: 1.6))
        head.append(oval(x: 14.3, y: 11.7, rx: 1.6, ry: 1.6))
        head.append(oval(x: 12, y: 15.4, rx: 1.1, ry: 0.8))
        head.windingRule = .evenOdd
        head.fill()
        oval(x: 7.6, y: 8.8, rx: 1.5, ry: 1.5).fill()
        oval(x: 16.4, y: 8.8, rx: 1.5, ry: 1.5).fill()
    }

    /// Template image for the menu bar: the head looking over an edge.
    static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { rect in
            let transform = NSAffineTransform()
            transform.scale(by: rect.width / 24)
            transform.concat()
            NSColor.black.setFill()
            fillHead()
            NSBezierPath(roundedRect: NSRect(x: 2, y: 19, width: 20, height: 2.2), xRadius: 1.1, yRadius: 1.1).fill()
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Meerkat"
        return image
    }

    /// Strokes the browser panel outline and fills the head looking up from its bottom edge.
    static func drawPanelPeek() {
        let panel = NSBezierPath(roundedRect: NSRect(x: 2.85, y: 2.85, width: 18.3, height: 18.3), xRadius: 4.4, yRadius: 4.4)
        panel.move(to: NSPoint(x: 2.85, y: 8))
        panel.line(to: NSPoint(x: 21.15, y: 8))
        panel.lineWidth = 1.7
        panel.stroke()
        NSGraphicsContext.saveGraphicsState()
        let transform = NSAffineTransform()
        transform.translateX(by: 12, yBy: 21.2)
        transform.scale(by: 0.66)
        transform.translateX(by: -12, yBy: -19)
        transform.concat()
        fillHead()
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func oval(x: CGFloat, y: CGFloat, rx: CGFloat, ry: CGFloat) -> NSBezierPath {
        NSBezierPath(ovalIn: NSRect(x: x - rx, y: y - ry, width: rx * 2, height: ry * 2))
    }
}
