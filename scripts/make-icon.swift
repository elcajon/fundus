// Rendert das App-Icon (hell und dunkel) und das Menüleisten-Symbol.
// Aufruf: swift scripts/make-icon.swift <Zielordner>
import AppKit

struct Theme {
    let top: NSColor
    let bottom: NSColor
    let ink: NSColor
    /// Feine Kante, damit das helle Icon auch auf dunklem Grund Kontur hat.
    let rim: NSColor
}

let light = Theme(top: NSColor(red: 0.98, green: 0.96, blue: 0.92, alpha: 1),
                  bottom: NSColor(red: 0.90, green: 0.87, blue: 0.80, alpha: 1),
                  ink: NSColor(red: 0.16, green: 0.17, blue: 0.18, alpha: 1),
                  rim: NSColor(red: 0.55, green: 0.50, blue: 0.42, alpha: 0.5))
let dark = Theme(top: NSColor(red: 0.23, green: 0.24, blue: 0.26, alpha: 1),
                 bottom: NSColor(red: 0.09, green: 0.10, blue: 0.11, alpha: 1),
                 ink: NSColor(red: 0.96, green: 0.94, blue: 0.90, alpha: 1),
                 rim: NSColor(white: 1, alpha: 0.12))

/// Zeichnet das Motiv in ein Quadrat der Kantenlänge `size`: Blattkontur mit einem F.
func draw(_ theme: Theme, size: CGFloat) {
    let s = size / 512
    let tile = NSBezierPath(roundedRect: NSRect(x: 50*s, y: 50*s, width: 412*s, height: 412*s),
                            xRadius: 92*s, yRadius: 92*s)
    NSGradient(starting: theme.top, ending: theme.bottom)!.draw(in: tile, angle: -90)
    theme.rim.setStroke()
    tile.lineWidth = 3*s
    tile.stroke()

    let sheet = NSBezierPath(roundedRect: NSRect(x: 151*s, y: 122*s, width: 210*s, height: 268*s),
                             xRadius: 26*s, yRadius: 26*s)
    sheet.lineWidth = 18*s
    theme.ink.setStroke()
    sheet.stroke()

    let font = NSFont.systemFont(ofSize: 150*s, weight: .medium)
    let text = NSAttributedString(string: "F", attributes: [.font: font, .foregroundColor: theme.ink])
    let bounds = text.boundingRect(with: .zero, options: [.usesDeviceMetrics])
    text.draw(at: NSPoint(x: 256*s - bounds.width/2 - bounds.minX, y: 252*s - bounds.height/2 - bounds.minY))
}

func image(_ theme: Theme, size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    draw(theme, size: size)
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

/// Menüleiste: nur das Motiv in Schwarz, macOS färbt es selbst ein (Template).
func menuBar(size: CGFloat) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = size / 36
    let sheet = NSBezierPath(roundedRect: NSRect(x: 8.5*s, y: 4.5*s, width: 19*s, height: 27*s),
                             xRadius: 4*s, yRadius: 4*s)
    sheet.lineWidth = 2.4*s
    NSColor.black.setStroke()
    sheet.stroke()
    let font = NSFont.systemFont(ofSize: 15*s, weight: .medium)
    let text = NSAttributedString(string: "F", attributes: [.font: font, .foregroundColor: NSColor.black])
    let bounds = text.boundingRect(with: .zero, options: [.usesDeviceMetrics])
    text.draw(at: NSPoint(x: 18*s - bounds.width/2 - bounds.minX, y: 18*s - bounds.height/2 - bounds.minY))
    NSGraphicsContext.current = nil
    return rep.representation(using: .png, properties: [:])!
}

let target = URL(fileURLWithPath: CommandLine.arguments[1])
for (name, theme) in [("AppIcon", light), ("AppIconDark", dark)] {
    let set = target.appending(path: "\(name).iconset")
    try? FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        try image(theme, size: CGFloat(base)).write(to: set.appending(path: "icon_\(base)x\(base).png"))
        try image(theme, size: CGFloat(base * 2)).write(to: set.appending(path: "icon_\(base)x\(base)@2x.png"))
    }
}
try menuBar(size: 36).write(to: target.appending(path: "MenuBarIcon.png"))
try menuBar(size: 72).write(to: target.appending(path: "MenuBarIcon@2x.png"))
