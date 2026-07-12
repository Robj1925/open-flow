// Renders the OpenFlow app icon at every required size and emits an .iconset
// folder for iconutil. Run: swift scripts/make-icon.swift <output-dir>
import AppKit

func drawIcon(canvas: CGFloat) {
    let scale = canvas / 1024.0

    // Full-bleed rounded square in Apple's modern icon proportions:
    // content occupies ~82% of the canvas, corner radius ~22.4% of that.
    let inset = 100.0 * scale
    let rect = NSRect(x: inset, y: inset, width: canvas - inset * 2, height: canvas - inset * 2)
    let radius = rect.width * 0.2237
    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.36, green: 0.24, blue: 0.92, alpha: 1.0), // indigo
        NSColor(calibratedRed: 0.10, green: 0.60, blue: 0.98, alpha: 1.0), // azure
        NSColor(calibratedRed: 0.15, green: 0.85, blue: 0.85, alpha: 1.0), // teal
    ])!
    gradient.draw(in: squircle, angle: -55)

    // Soft highlight across the top for depth.
    let highlight = NSGradient(colors: [
        NSColor(calibratedWhite: 1.0, alpha: 0.22),
        NSColor(calibratedWhite: 1.0, alpha: 0.0),
    ])!
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    let highlightRect = NSRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
    highlight.draw(in: highlightRect, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // The waveform — same silhouette as the recording HUD.
    let heights: [CGFloat] = [0.20, 0.38, 0.62, 0.92, 0.70, 0.50, 0.78, 0.42, 0.24]
    let barWidth = rect.width * 0.055
    let gap = rect.width * 0.041
    let totalWidth = CGFloat(heights.count) * barWidth + CGFloat(heights.count - 1) * gap
    var x = rect.midX - totalWidth / 2

    let shadow = NSShadow()
    shadow.shadowColor = NSColor(calibratedWhite: 0, alpha: 0.25)
    shadow.shadowBlurRadius = 14 * scale
    shadow.shadowOffset = NSSize(width: 0, height: -6 * scale)
    NSGraphicsContext.current?.saveGraphicsState()
    shadow.set()
    NSColor.white.setFill()
    for height in heights {
        let barHeight = rect.height * height * 0.60
        let bar = NSRect(x: x, y: rect.midY - barHeight / 2, width: barWidth, height: barHeight)
        NSBezierPath(roundedRect: bar, xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
        x += barWidth + gap
    }
    NSGraphicsContext.current?.restoreGraphicsState()
}

func renderPNG(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    drawIcon(canvas: CGFloat(pixels))
    context.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let outputDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "OpenFlow.iconset"
try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

let entries: [(points: Int, scale: Int)] = [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
    (256, 1), (256, 2), (512, 1), (512, 2),
]
for entry in entries {
    let pixels = entry.points * entry.scale
    let suffix = entry.scale == 2 ? "@2x" : ""
    let filename = "\(outputDir)/icon_\(entry.points)x\(entry.points)\(suffix).png"
    try renderPNG(pixels: pixels).write(to: URL(fileURLWithPath: filename))
    print("wrote \(filename) (\(pixels)px)")
}
