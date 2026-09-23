// Renders the app icon into an .iconset folder: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int) -> Data? {
    let scale = CGFloat(size) / 1024
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
        hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    ) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }

    let tile = NSRect(x: 100, y: 100, width: 824, height: 824).applying(CGAffineTransform(scaleX: scale, y: scale))
    let path = NSBezierPath(roundedRect: tile, xRadius: 186 * scale, yRadius: 186 * scale)
    NSGradient(colors: [
        NSColor(srgbRed: 0.03, green: 0.76, blue: 0.38, alpha: 1),
        NSColor(srgbRed: 0.02, green: 0.55, blue: 0.47, alpha: 1),
    ])?.draw(in: path, angle: -90)

    NSColor.white.withAlphaComponent(0.22).setStroke()
    for (index, radius) in [250.0, 330.0].enumerated() {
        let arc = NSBezierPath()
        let center = NSPoint(x: 512 * scale, y: 560 * scale)
        arc.appendArc(withCenter: center, radius: radius * scale, startAngle: -40, endAngle: 40)
        let mirrored = NSBezierPath()
        mirrored.appendArc(withCenter: center, radius: radius * scale, startAngle: 140, endAngle: 220)
        for piece in [arc, mirrored] {
            piece.lineWidth = CGFloat(34 - index * 8) * scale
            piece.lineCapStyle = .round
            piece.stroke()
        }
    }

    let config = NSImage.SymbolConfiguration(pointSize: 420 * scale, weight: .semibold)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let symbolSize = symbol.size
        let origin = NSPoint(x: (CGFloat(size) - symbolSize.width) / 2, y: (CGFloat(size) - symbolSize.height) / 2 + 30 * scale)
        symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)
    }
    return rep.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in variants {
    guard let data = render(size: size) else { fatalError("could not render \(name)") }
    try data.write(to: output.appendingPathComponent("\(name).png"))
}
print("icon written to \(output.path)")
