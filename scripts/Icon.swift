import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let body = NSBezierPath(roundedRect: NSRect(x: 58, y: 58, width: 908, height: 908), xRadius: 205, yRadius: 205)
        let gradient = NSGradient(starting: NSColor(red: 0.08, green: 0.33, blue: 0.31, alpha: 1),
                                  ending: NSColor(red: 0.16, green: 0.60, blue: 0.49, alpha: 1))!
        gradient.draw(in: body, angle: 70)
        NSColor.white.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: NSRect(x: 350, y: 238, width: 324, height: 548), xRadius: 106, yRadius: 106).fill()
        NSColor(red: 0.09, green: 0.40, blue: 0.35, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 412, y: 323, width: 200, height: 200)).fill()
        NSColor.white.withAlphaComponent(0.80).setFill()
        NSBezierPath(ovalIn: NSRect(x: 469, y: 380, width: 86, height: 86)).fill()
        NSColor(red: 0.16, green: 0.60, blue: 0.49, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 448, y: 651, width: 128, height: 22), xRadius: 11, yRadius: 11).fill()
        NSColor.white.withAlphaComponent(0.60).setStroke()
        for x: CGFloat in [250, 755] {
            let wave = NSBezierPath()
            wave.move(to: NSPoint(x: x, y: 450))
            wave.curve(to: NSPoint(x: x, y: 610), controlPoint1: NSPoint(x: x + (x < 500 ? -30 : 30), y: 495),
                       controlPoint2: NSPoint(x: x + (x < 500 ? -30 : 30), y: 565))
            wave.lineWidth = 22; wave.lineCapStyle = .round; wave.stroke()
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("icon_\(size)x\(size)\(suffix).png"))
    }
}
