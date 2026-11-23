import AppKit
import Foundation

// Renders a crisp macOS squircle app icon featuring the 3D interlocking Colab Ribbon
// into a .iconset folder ready for `iconutil -c icns`.

guard CommandLine.arguments.count >= 2 else {
    fputs("Usage: swift generate_icns.swift <output.iconset>\n", stderr)
    exit(1)
}

let iconsetPath = CommandLine.arguments[1]
let fm = FileManager.default
try? fm.removeItem(atPath: iconsetPath)
try fm.createDirectory(atPath: iconsetPath, withIntermediateDirectories: true)

func renderIcon(pixels: Int) -> Data? {
    let size = CGFloat(pixels)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    NSGraphicsContext.saveGraphicsState()
    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)

    // macOS Big Sur / Sonoma icon safe canvas (~82.5% centered squircle)
    let margin = size * 0.088
    let tile = CGRect(x: margin, y: margin, width: size - 2 * margin, height: size - 2 * margin)
    let corner = tile.width * 0.225
    let tilePath = CGPath(roundedRect: tile, cornerWidth: corner, cornerHeight: corner, transform: nil)

    // Subtle soft drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -size * 0.018), blur: size * 0.04, color: NSColor.black.withAlphaComponent(0.32).cgColor)
    ctx.addPath(tilePath)
    ctx.setFillColor(NSColor(srgbRed: 0.11, green: 0.11, blue: 0.13, alpha: 1.0).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Clip to squircle and fill dark satin vertical gradient
    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bgColors = [
        NSColor(srgbRed: 0.18, green: 0.18, blue: 0.21, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.09, green: 0.09, blue: 0.11, alpha: 1.0).cgColor
    ] as CFArray
    if let grad = CGGradient(colorsSpace: colorSpace, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
    }

    // Subtle warm radial ambient glow behind emblem
    let glowColors = [
        NSColor(srgbRed: 0.98, green: 0.65, blue: 0.10, alpha: 0.18).cgColor,
        NSColor(srgbRed: 0.98, green: 0.65, blue: 0.10, alpha: 0.00).cgColor
    ] as CFArray
    if let glow = CGGradient(colorsSpace: colorSpace, colors: glowColors, locations: [0.0, 1.0]) {
        let center = CGPoint(x: size * 0.5, y: size * 0.52)
        ctx.drawRadialGradient(glow, startCenter: center, startRadius: 0, endCenter: center, endRadius: tile.width * 0.46, options: [])
    }

    // Draw interlocking 3D Colab Ribbon in 24x24 y-down coordinates centered on tile
    ctx.saveGState()
    let emblemSize = tile.width * 0.72
    let s = emblemSize / 24.0
    let originX = (size - emblemSize) * 0.5
    let originY = (size - emblemSize) * 0.5
    ctx.translateBy(x: originX, y: size - originY)
    ctx.scaleBy(x: s, y: -s)

    let primary = NSColor(srgbRed: 0.988, green: 0.757, blue: 0.145, alpha: 1.0)
    let secondary = NSColor(srgbRed: 0.918, green: 0.365, blue: 0.055, alpha: 1.0)

    ctx.setLineWidth(3.35)
    ctx.setLineCap(.round)
    let c1 = CGPoint(x: 8.46, y: 12.0)
    let c2 = CGPoint(x: 15.54, y: 12.0)
    let r: CGFloat = 5.0

    // Back halves (deep amber)
    ctx.setStrokeColor(secondary.cgColor)
    ctx.beginPath()
    ctx.addArc(center: c2, radius: r, startAngle: -.pi / 4, endAngle: 3 * .pi / 4, clockwise: true)
    ctx.strokePath()

    ctx.beginPath()
    ctx.addArc(center: c1, radius: r, startAngle: 3 * .pi / 4, endAngle: .pi / 4, clockwise: true)
    ctx.strokePath()

    // Subtle soft shadow under front sweeping halves
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 0.4), blur: 1.0, color: NSColor.black.withAlphaComponent(0.35).cgColor)
    ctx.setStrokeColor(primary.cgColor)
    ctx.beginPath()
    ctx.addArc(center: c1, radius: r, startAngle: -.pi / 4, endAngle: 3 * .pi / 4, clockwise: true)
    ctx.strokePath()

    ctx.beginPath()
    ctx.addArc(center: c2, radius: r, startAngle: 3 * .pi / 4, endAngle: -.pi / 4, clockwise: true)
    ctx.strokePath()
    ctx.restoreGState()

    ctx.restoreGState() // end emblem transform
    ctx.restoreGState() // end tile clip

    // Crisp hairline inner rim highlight
    ctx.addPath(tilePath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.14).cgColor)
    ctx.setLineWidth(max(1.0, size * 0.004))
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (filename, px) in specs {
    if let png = renderIcon(pixels: px) {
        try png.write(to: URL(fileURLWithPath: "\(iconsetPath)/\(filename)"))
    }
}
