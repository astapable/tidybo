// Renders the app icon (the trigger's robot head) into an .iconset and builds AppIcon.icns.
// Usage: swift Tools/make_icon.swift <output-dir>
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "build")
let iconset = out.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}
let glow = CGColor(srgbRed: 0.38, green: 0.86, blue: 1, alpha: 1)

func linear(_ ctx: CGContext, _ path: CGPath, _ hex: [UInt32], _ locs: [CGFloat], top: CGFloat, bottom: CGFloat) {
    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: hex.map { rgb($0) } as CFArray, locations: locs)!
    ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: top), end: CGPoint(x: 0, y: bottom), options: [])
    ctx.restoreGState()
}

func pixels(_ ctx: CGContext, _ rows: [String], center c: CGPoint, px: CGFloat) {
    let w = CGFloat(rows.map(\.count).max() ?? 0) * px, h = CGFloat(rows.count) * px
    let x0 = c.x - w / 2, yTop = c.y + h / 2
    for (ri, row) in rows.enumerated() {
        for (ci, ch) in row.enumerated() where ch == "#" {
            let r = CGRect(x: x0 + CGFloat(ci) * px, y: yTop - CGFloat(ri + 1) * px, width: px, height: px).insetBy(dx: px * 0.1, dy: px * 0.1)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: px * 0.24, cornerHeight: px * 0.24, transform: nil))
        }
    }
}

/// Draws the icon on a 1024×1024 canvas (y up): a black tile with just the glowing pixel face.
func drawIcon(_ ctx: CGContext) {
    let S: CGFloat = 1024
    // macOS-style squircle tile, black with a very subtle top sheen.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(tilePath)
    ctx.setFillColor(rgb(0x000000))
    ctx.fillPath()
    ctx.restoreGState()
    linear(ctx, tilePath, [0x1A1C20, 0x050506, 0x000000], [0, 0.45, 1], top: tile.maxY, bottom: tile.minY)
    ctx.addPath(tilePath); ctx.setStrokeColor(rgb(0xFFFFFF, 0.08)); ctx.setLineWidth(3); ctx.strokePath()

    // Face, same proportions as the trigger's (eyes ±17, mouth 11 below the eye line, 2.5 px).
    let k: CGFloat = 13
    let fc = CGPoint(x: S / 2, y: S / 2 + 10)
    let px = 2.5 * k
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 3.5 * k * 1.8, color: glow)
    ctx.setFillColor(glow)
    let eye = [".##.", "####", "####", "####", "####", ".##."]
    pixels(ctx, eye, center: CGPoint(x: fc.x - 17 * k, y: fc.y + 1 * k), px: px)
    pixels(ctx, eye, center: CGPoint(x: fc.x + 17 * k, y: fc.y + 1 * k), px: px)
    pixels(ctx, ["####", ".##."], center: CGPoint(x: fc.x, y: fc.y - 10 * k), px: px)
    ctx.fillPath()
    ctx.restoreGState()
}

let sizes: [(String, Int)] = [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                              ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)]
for (name, px) in sizes {
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    drawIcon(ctx)
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent("icon_\(name).png"))
}
print(iconset.path)
