import AppKit
import Foundation

// Composes studio-grade Retina showcase PNGs for the GitHub README from raw app renders.
// Usage: swift scripts/compose_assets.swift <raw_dir> <assets_dir>

guard CommandLine.arguments.count >= 3 else {
    fputs("Usage: swift compose_assets.swift <raw_dir> <assets_dir>\n", stderr)
    exit(1)
}

let rawDir = CommandLine.arguments[1]
let outDir = CommandLine.arguments[2]
try FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func loadCG(_ name: String) -> CGImage {
    let url = URL(fileURLWithPath: "\(rawDir)/\(name)")
    guard let ns = NSImage(contentsOf: url),
          let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        fatalError("Failed to load \(url.path)")
    }
    return cg
}

struct CardSpec {
    let image: CGImage
    let label: String
    let isLight: Bool
    let yOffset: CGFloat
}

func composeCanvas(
    width: Int,
    height: Int,
    cards: [CardSpec],
    cardW: CGFloat,
    cardH: CGFloat,
    gap: CGFloat,
    drawArrowBetween: Bool = false,
    outputPath: String
) {
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { fatalError("Bitmap allocation failed") }

    NSGraphicsContext.saveGraphicsState()
    guard let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else { fatalError("Context failed") }
    NSGraphicsContext.current = nsCtx
    let ctx = nsCtx.cgContext
    ctx.setShouldAntialias(true)
    ctx.setAllowsAntialiasing(true)
    ctx.interpolationQuality = .high

    let W = CGFloat(width)
    let H = CGFloat(height)
    let cs = CGColorSpaceCreateDeviceRGB()

    // Rounded studio backdrop
    let outerRect = CGRect(x: 0, y: 0, width: W, height: H)
    let outerPath = CGPath(roundedRect: outerRect, cornerWidth: 28, cornerHeight: 28, transform: nil)
    ctx.saveGState()
    ctx.addPath(outerPath)
    ctx.clip()

    // Deep slate-charcoal diagonal gradient
    let bgColors = [
        NSColor(srgbRed: 0.085, green: 0.090, blue: 0.110, alpha: 1.0).cgColor,
        NSColor(srgbRed: 0.055, green: 0.058, blue: 0.070, alpha: 1.0).cgColor
    ] as CFArray
    if let g = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0.0, 1.0]) {
        ctx.drawLinearGradient(g, start: CGPoint(x: 0, y: H), end: CGPoint(x: W, y: 0), options: [])
    }

    // Subtle warm top-center glow + cool bottom-right glow
    let warmGlow = [
        NSColor(srgbRed: 0.98, green: 0.65, blue: 0.12, alpha: 0.11).cgColor,
        NSColor(srgbRed: 0.98, green: 0.65, blue: 0.12, alpha: 0.00).cgColor
    ] as CFArray
    if let rg = CGGradient(colorsSpace: cs, colors: warmGlow, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(rg, startCenter: CGPoint(x: W * 0.5, y: H * 0.88), startRadius: 0, endCenter: CGPoint(x: W * 0.5, y: H * 0.88), endRadius: W * 0.55, options: [])
    }

    let coolGlow = [
        NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 0.09).cgColor,
        NSColor(srgbRed: 0.35, green: 0.55, blue: 0.95, alpha: 0.00).cgColor
    ] as CFArray
    if let rg2 = CGGradient(colorsSpace: cs, colors: coolGlow, locations: [0.0, 1.0]) {
        ctx.drawRadialGradient(rg2, startCenter: CGPoint(x: W * 0.82, y: H * 0.16), startRadius: 0, endCenter: CGPoint(x: W * 0.82, y: H * 0.16), endRadius: W * 0.42, options: [])
    }

    // Layout cards horizontally centered
    let count = CGFloat(cards.count)
    let totalW = count * cardW + max(0, count - 1) * gap
    let startX = (W - totalW) * 0.5
    let baseY = (H - cardH) * 0.5 + 14.0

    for (idx, spec) in cards.enumerated() {
        let x = startX + CGFloat(idx) * (cardW + gap)
        let y = baseY + spec.yOffset
        let rect = CGRect(x: x, y: y, width: cardW, height: cardH)
        let cardPath = CGPath(roundedRect: rect, cornerWidth: 20, cornerHeight: 20, transform: nil)

        // Deep soft macOS popover drop shadow
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 44, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.addPath(cardPath)
        ctx.setFillColor(spec.isLight ? NSColor(srgbRed: 0.96, green: 0.96, blue: 0.97, alpha: 1).cgColor : NSColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()

        // Draw crisp rounded Retina card image
        ctx.saveGState()
        ctx.addPath(cardPath)
        ctx.clip()
        ctx.draw(spec.image, in: rect)
        ctx.restoreGState()

        // Crisp hairline rim border
        ctx.addPath(cardPath)
        ctx.setStrokeColor(spec.isLight ? NSColor.white.withAlphaComponent(0.35).cgColor : NSColor.white.withAlphaComponent(0.14).cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()

        // Centered caption below card
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 22, weight: .medium),
            .foregroundColor: NSColor(srgbRed: 0.80, green: 0.82, blue: 0.86, alpha: 0.92),
            .paragraphStyle: para
        ]
        let labelRect = CGRect(x: x, y: baseY - 50, width: cardW, height: 32)
        (spec.label as NSString).draw(in: labelRect, withAttributes: attrs)
    }

    if drawArrowBetween && cards.count == 2 {
        let midX = W * 0.5
        let midY = baseY + cardH * 0.5
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        ctx.setLineWidth(3.0)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: midX - 18, y: midY))
        ctx.addLine(to: CGPoint(x: midX + 16, y: midY))
        ctx.move(to: CGPoint(x: midX + 6, y: midY + 10))
        ctx.addLine(to: CGPoint(x: midX + 16, y: midY))
        ctx.addLine(to: CGPoint(x: midX + 6, y: midY - 10))
        ctx.strokePath()
    }

    ctx.restoreGState()

    // Subtle outer studio frame rim
    ctx.addPath(outerPath)
    ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.08).cgColor)
    ctx.setLineWidth(2.0)
    ctx.strokePath()

    NSGraphicsContext.restoreGraphicsState()

    if let png = rep.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: outputPath))
    }
}

let sessionsDark  = loadCG("raw_sessions_dark.png")
let logsDark      = loadCG("raw_logs_dark.png")
let logsLight     = loadCG("raw_logs_light.png")
let histListDark  = loadCG("raw_history_list_dark.png")
let histDetDark   = loadCG("raw_history_detail_dark.png")
let styleDarkCol  = loadCG("raw_style_dark_color.png")
let styleLightMon = loadCG("raw_style_light_mono.png")

// 1. Hero 3-up showcase (Sessions · Syntax-Highlighted Logs · History)
composeCanvas(
    width: 1920, height: 920,
    cards: [
        CardSpec(image: sessionsDark, label: "Live Sessions & Controls", isLight: false, yOffset: -8),
        CardSpec(image: logsDark,     label: "Syntax-Highlighted Logs",  isLight: false, yOffset: 16),
        CardSpec(image: histListDark, label: "Full Session History",     isLight: false, yOffset: -8)
    ],
    cardW: 540, cardH: 676, gap: 56,
    outputPath: "\(outDir)/hero.png"
)

// 2. History Master → Detail replay
composeCanvas(
    width: 1440, height: 880,
    cards: [
        CardSpec(image: histListDark, label: "Day-Grouped Runs & Active Duration", isLight: false, yOffset: 0),
        CardSpec(image: histDetDark,  label: "Full Syntax-Highlighted Replay",     isLight: false, yOffset: 0)
    ],
    cardW: 540, cardH: 676, gap: 112,
    drawArrowBetween: true,
    outputPath: "\(outDir)/history.png"
)

// 3. 6 Retina Vector Icons × Color / Monochrome + Settings
composeCanvas(
    width: 1440, height: 880,
    cards: [
        CardSpec(image: styleDarkCol,  label: "6 Vector Icons · Color (Dark)",       isLight: false, yOffset: 0),
        CardSpec(image: styleLightMon, label: "Native Monochrome · Settings (Light)", isLight: true,  yOffset: 0)
    ],
    cardW: 540, cardH: 676, gap: 96,
    outputPath: "\(outDir)/icons.png"
)

// 4. Adaptive Dark & Light Syntax Highlighting
composeCanvas(
    width: 1440, height: 880,
    cards: [
        CardSpec(image: logsDark,  label: "Dark Mode · Adaptive Syntax Palette",  isLight: false, yOffset: 0),
        CardSpec(image: logsLight, label: "Light Mode · Adaptive Syntax Palette", isLight: true,  yOffset: 0)
    ],
    cardW: 540, cardH: 676, gap: 96,
    outputPath: "\(outDir)/themes.png"
)

print("ASSETS_COMPOSED_OK")
