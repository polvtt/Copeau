// Génère Resources/AppIcon.icns : swift Tools/make_icon.swift <dossier-temporaire>
// Un copeau de bois (spirale) posé sur deux cartes de presse-papiers.
import AppKit

func draw(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024
    let body = NSRect(x: 100 * s, y: 100 * s, width: 824 * s, height: 824 * s)
    let path = NSBezierPath(roundedRect: body, xRadius: 185 * s, yRadius: 185 * s)
    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow(); shadow.shadowBlurRadius = 24 * s; shadow.shadowOffset = NSSize(width: 0, height: -10 * s)
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.3); shadow.set()
    NSColor.black.setFill(); path.fill()
    NSGraphicsContext.current?.restoreGraphicsState()
    NSGradient(colors: [NSColor(srgbRed: 0.99, green: 0.74, blue: 0.36, alpha: 1), NSColor(srgbRed: 0.86, green: 0.42, blue: 0.16, alpha: 1)])!
        .draw(in: path, angle: -60)

    // Deux cartes décalées.
    func card(_ x: CGFloat, _ y: CGFloat, _ alpha: CGFloat) {
        let r = NSRect(x: x * s, y: y * s, width: 430 * s, height: 500 * s)
        NSGraphicsContext.current?.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 18 * s; sh.shadowOffset = NSSize(width: 0, height: -6 * s)
        sh.shadowColor = NSColor.black.withAlphaComponent(0.22); sh.set()
        NSColor.white.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: r, xRadius: 46 * s, yRadius: 46 * s).fill()
        NSGraphicsContext.current?.restoreGraphicsState()
        NSColor(srgbRed: 0.86, green: 0.42, blue: 0.16, alpha: alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: r.minX, y: r.maxY - 90 * s, width: r.width, height: 90 * s), xRadius: 46 * s, yRadius: 46 * s).fill()
        NSBezierPath(rect: NSRect(x: r.minX, y: r.maxY - 90 * s, width: r.width, height: 46 * s)).fill()
        NSColor(white: 0.78, alpha: alpha).setFill()
        for (i, w) in [330.0, 280.0, 340.0, 220.0].enumerated() {
            NSBezierPath(roundedRect: NSRect(x: r.minX + 46 * s, y: r.maxY - (160 + Double(i) * 62) * s, width: w * s, height: 26 * s),
                         xRadius: 13 * s, yRadius: 13 * s).fill()
        }
    }
    card(220, 230, 0.75)
    card(370, 300, 1)

    // Copeau : spirale d'Archimède épaisse, du bois clair au bois sombre.
    let spiral = NSBezierPath()
    let cx = 640.0, cy = 330.0
    var first = true
    for i in 0...220 {
        let t = Double(i) / 220 * 2.6 * .pi
        let r = 18 + 30 * t
        let p = NSPoint(x: (cx + r * cos(t + 0.6)) * s, y: (cy + r * sin(t + 0.6)) * s)
        if first { spiral.move(to: p); first = false } else { spiral.line(to: p) }
    }
    spiral.lineCapStyle = .round
    spiral.lineJoinStyle = .round
    spiral.lineWidth = 46 * s
    NSGraphicsContext.current?.saveGraphicsState()
    let sh = NSShadow(); sh.shadowBlurRadius = 14 * s; sh.shadowOffset = NSSize(width: 0, height: -5 * s)
    sh.shadowColor = NSColor.black.withAlphaComponent(0.3); sh.set()
    NSColor(srgbRed: 0.55, green: 0.27, blue: 0.10, alpha: 1).setStroke()
    spiral.stroke()
    NSGraphicsContext.current?.restoreGraphicsState()
    spiral.lineWidth = 26 * s
    NSColor(srgbRed: 0.98, green: 0.84, blue: 0.58, alpha: 1).setStroke()
    spiral.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        try! draw(base * scale).representation(using: .png, properties: [:])!.write(to: dir.appendingPathComponent(name))
    }
}
