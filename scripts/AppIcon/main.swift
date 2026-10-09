// Renders the app icon into an .iconset folder for `iconutil`.
// Built with Sources/Meerkat/MeerkatGlyph.swift; see scripts/build-macos.sh.
// Usage: AppIcon <output.iconset>
import AppKit

/// Draws the icon on a 1024-point canvas with a top-left origin, on the standard macOS grid:
/// an 824-point rounded square, centered, with a soft shadow below it.
func drawIcon() {
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let shape = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowBlurRadius = 24
    shadow.set()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    // Sky, light at the top. In this flipped space, angle 90 runs from the top edge down.
    let sky = NSGradient(starting: NSColor(srgbRed: 0.30, green: 0.59, blue: 1.0, alpha: 1),
                         ending: NSColor(srgbRed: 0.11, green: 0.29, blue: 0.69, alpha: 1))!
    sky.draw(in: shape, angle: 90)
    // The artwork fills 69% of the body, as in the design sketch.
    let scale = body.width * 0.69 / 24
    let transform = NSAffineTransform()
    transform.translateX(by: body.minX + body.width * 0.155, yBy: body.minY + body.width * 0.155)
    transform.scale(by: scale)
    transform.concat()
    let cream = NSColor(srgbRed: 1.0, green: 0.906, blue: 0.749, alpha: 1)
    cream.setStroke()
    cream.setFill()
    MeerkatGlyph.drawPanelPeek()
}

func png(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    let cg = context.cgContext
    // Flip to a top-left origin and scale the 1024-point design to this size.
    cg.translateBy(x: 0, y: CGFloat(pixels))
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: -CGFloat(pixels) / 1024)
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: AppIcon <output.iconset>\n".utf8))
    exit(2)
}
let folder = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(pixels: points).write(to: folder.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(pixels: points * 2).write(to: folder.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
