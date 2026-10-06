// Generates Resources/Assets.xcassets/AppIcon.appiconset from code. Run: swift scripts/make-icon.swift
import AppKit

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let image = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
        let inset = s * 0.085
        let body = rect.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: body, xRadius: body.width * 0.2237, yRadius: body.width * 0.2237)
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        // Deep blue → violet, lit from the top left.
        NSGradient(colors: [NSColor(red: 0.20, green: 0.52, blue: 1.00, alpha: 1), NSColor(red: 0.45, green: 0.28, blue: 0.98, alpha: 1)],
                   atLocations: [0, 1], colorSpace: .sRGB)!.draw(in: body, angle: -60)
        // Soft highlight.
        NSGradient(colors: [NSColor.white.withAlphaComponent(0.28), NSColor.white.withAlphaComponent(0)], atLocations: [0, 1], colorSpace: .sRGB)!
            .draw(in: NSRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
        NSGraphicsContext.restoreGraphicsState()

        // Magnifier: ring + handle, white with a gentle shadow.
        let ctx = NSGraphicsContext.current!.cgContext
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: NSColor.black.withAlphaComponent(0.3).cgColor)
        let c = CGPoint(x: s * 0.46, y: s * 0.56), r = s * 0.20
        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(s * 0.075)
        ctx.setLineCap(.round)
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        ctx.move(to: CGPoint(x: c.x + r * 0.72, y: c.y - r * 0.72))
        ctx.addLine(to: CGPoint(x: s * 0.72, y: s * 0.30))
        ctx.strokePath()
        ctx.restoreGState()

        // A small spark inside the lens.
        let star = NSBezierPath()
        let sc = CGPoint(x: c.x - r * 0.05, y: c.y + r * 0.02), sr = r * 0.46
        for i in 0..<8 {
            let a = CGFloat(i) * .pi / 4
            let rad = i % 2 == 0 ? sr : sr * 0.28
            let p = CGPoint(x: sc.x + cos(a + .pi / 2) * rad, y: sc.y + sin(a + .pi / 2) * rad)
            i == 0 ? star.move(to: p) : star.line(to: p)
        }
        star.close()
        NSColor.white.withAlphaComponent(0.95).setFill()
        star.fill()
        return true
    }
    let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
    return rep.representation(using: .png, properties: [:])!
}

let dir = "Resources/Assets.xcassets/AppIcon.appiconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
var images: [[String: String]] = []
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = "icon_\(base)x\(base)@\(scale)x.png"
        try! render(size: px).write(to: URL(fileURLWithPath: "\(dir)/\(name)"))
        images.append(["idiom": "mac", "size": "\(base)x\(base)", "scale": "\(scale)x", "filename": name])
    }
}
let json = try! JSONSerialization.data(withJSONObject: ["images": images, "info": ["author": "xcode", "version": 1]], options: [.prettyPrinted, .sortedKeys])
try! json.write(to: URL(fileURLWithPath: "\(dir)/Contents.json"))
print("icon written")
