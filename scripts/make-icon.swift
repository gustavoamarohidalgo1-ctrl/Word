import Cocoa

guard CommandLine.arguments.count > 1 else {
    fputs("Usage: swift make-icon.swift <iconset_dir>\n", stderr)
    exit(1)
}

let iconsetDir = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func renderIcon(px: Int) -> Data? {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: px, height: px)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(px)
    let pad = s * 0.08
    let box = NSRect(x: pad, y: pad, width: s - 2 * pad, height: s - 2 * pad)
    let radius = s * 0.21

    let bgPath = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)
    let gradient = NSGradient(
        starting: NSColor(calibratedRed: 0.09, green: 0.30, blue: 0.85, alpha: 1.0),
        ending: NSColor(calibratedRed: 0.20, green: 0.52, blue: 0.98, alpha: 1.0)
    )!
    gradient.draw(in: bgPath, angle: 60)

    // Subtle document lines behind W
    NSColor(white: 1.0, alpha: 0.22).setFill()
    for i in 0..<3 {
        let ly = s * (0.28 + CGFloat(i) * 0.14)
        let lw = i == 0 ? s * 0.44 : s * 0.54
        let lineRect = NSRect(x: (s - lw) / 2, y: ly, width: lw, height: max(2, s * 0.045))
        NSBezierPath(roundedRect: lineRect, xRadius: s * 0.02, yRadius: s * 0.02).fill()
    }

    // Crisp "W" badge
    let font = NSFont.systemFont(ofSize: s * 0.50, weight: .heavy)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor.white
    ]
    let str = NSAttributedString(string: "W", attributes: attrs)
    let textSize = str.size()
    let textRect = NSRect(
        x: (s - textSize.width) / 2,
        y: (s - textSize.height) / 2 + s * 0.01,
        width: textSize.width,
        height: textSize.height
    )
    str.draw(in: textRect)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for (px, name) in sizes {
    if let data = renderIcon(px: px) {
        try data.write(to: iconsetDir.appendingPathComponent(name))
    }
}
