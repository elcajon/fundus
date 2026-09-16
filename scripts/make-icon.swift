// Rendert das App-Icon: ein kleiner Papierstapel auf warmem Grund.
import AppKit

func render(_ size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 1024
    let bg = NSBezierPath(roundedRect: NSRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s), xRadius: 185*s, yRadius: 185*s)
    NSGradient(starting: NSColor(red: 0.98, green: 0.62, blue: 0.36, alpha: 1),
               ending: NSColor(red: 0.86, green: 0.33, blue: 0.27, alpha: 1))!.draw(in: bg, angle: -90)
    let sheets: [(CGFloat, CGFloat, CGFloat)] = [(-10, -34, 0.78), (6, 22, 0.9), (0, 0, 1)]
    for (angle, dx, alpha) in sheets {
        NSGraphicsContext.saveGraphicsState()
        let t = NSAffineTransform()
        t.translateX(by: 512*s + dx*s, yBy: 500*s); t.rotate(byDegrees: angle); t.concat()
        let shadow = NSShadow(); shadow.shadowBlurRadius = 24*s; shadow.shadowOffset = NSSize(width: 0, height: -8*s)
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22); shadow.set()
        NSColor(white: 1, alpha: alpha).setFill()
        NSBezierPath(roundedRect: NSRect(x: -200*s, y: -270*s, width: 400*s, height: 540*s), xRadius: 22*s, yRadius: 22*s).fill()
        NSGraphicsContext.restoreGraphicsState()
    }
    NSColor(red: 0.86, green: 0.33, blue: 0.27, alpha: 0.9).setFill()
    NSBezierPath(roundedRect: NSRect(x: 372*s, y: 640*s, width: 200*s, height: 30*s), xRadius: 15*s, yRadius: 15*s).fill()
    NSColor(white: 0.8, alpha: 1).setFill()
    for i in 0..<6 {
        let w: CGFloat = i == 5 ? 160 : 280
        NSBezierPath(roundedRect: NSRect(x: 372*s, y: (570 - CGFloat(i)*62)*s, width: w*s, height: 22*s), xRadius: 11*s, yRadius: 11*s).fill()
    }
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(CGFloat(base)).write(to: dir.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(CGFloat(base * 2)).write(to: dir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
