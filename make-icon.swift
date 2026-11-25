import AppKit

let destination = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)

func drawIcon(size: Int) -> Data {
    let pixels = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: pixels)
    let scale = NSAffineTransform()
    scale.scale(by: CGFloat(size) / 1024)
    scale.concat()

    let tile = NSBezierPath(roundedRect: NSRect(x: 90, y: 90, width: 844, height: 844),
                            xRadius: 195, yRadius: 195)
    let navy = NSColor(srgbRed: 0.08, green: 0.16, blue: 0.29, alpha: 1)
    let blue = NSColor(srgbRed: 0.16, green: 0.32, blue: 0.55, alpha: 1)
    NSGradient(starting: navy, ending: blue)!.draw(in: tile, angle: 55)

    let mouse = NSBezierPath(roundedRect: NSRect(x: 321, y: 230, width: 382, height: 564),
                             xRadius: 166, yRadius: 166)
    NSColor(srgbRed: 0.91, green: 0.96, blue: 1, alpha: 1).setFill()
    mouse.fill()

    NSGraphicsContext.saveGraphicsState()
    mouse.addClip()
    let band = NSRect(x: 460, y: 230, width: 104, height: 564)
    let brightBlue = NSColor(srgbRed: 0.12, green: 0.44, blue: 0.90, alpha: 1)
    brightBlue.setFill()
    NSBezierPath(rect: band).fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return pixels.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try drawIcon(size: size).write(to: destination.appendingPathComponent("icon_\(size)x\(size).png"))
    try drawIcon(size: size * 2).write(to: destination.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
