import AppKit

// memterm app icon generator — brand: warm near-black + amber phosphor.
// Motif: ghost scrollback above the "restored" divider, live prompt below.

let amber = NSColor(calibratedRed: 0.910, green: 0.628, blue: 0.298, alpha: 1)      // #e8a04c
let amberHot = NSColor(calibratedRed: 0.949, green: 0.698, blue: 0.392, alpha: 1)   // #f2b264
let ghost = NSColor(calibratedRed: 0.541, green: 0.490, blue: 0.388, alpha: 1)      // #8a7d63
let bgTop = NSColor(calibratedRed: 0.129, green: 0.104, blue: 0.080, alpha: 1)      // #211a14
let bgBottom = NSColor(calibratedRed: 0.071, green: 0.055, blue: 0.043, alpha: 1)   // #120e0b

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .calibratedRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px) / 1024.0

    // macOS icon grid: 824pt artwork centered in 1024 canvas, r≈185
    let plate = NSBezierPath(roundedRect: NSRect(x: 100*s, y: 100*s, width: 824*s, height: 824*s),
                             xRadius: 185*s, yRadius: 185*s)
    NSGradient(starting: bgTop, ending: bgBottom)!.draw(in: plate, angle: -90)
    amber.withAlphaComponent(0.16).setStroke()
    plate.lineWidth = max(2*s, 1)
    plate.stroke()

    // ghost scrollback bars (dimmed history, top-left aligned like text)
    let barX: CGFloat = 232
    for (i, w, a) in [(0, CGFloat(400), 0.34), (1, CGFloat(300), 0.27), (2, CGFloat(452), 0.20)] {
        let y = 812 - CGFloat(i) * 92   // top of each 44pt bar
        let bar = NSBezierPath(roundedRect: NSRect(x: barX*s, y: (y-44)*s, width: w*s, height: 44*s),
                               xRadius: 22*s, yRadius: 22*s)
        ghost.withAlphaComponent(a).setFill()
        bar.fill()
    }

    // the "restored —" divider: three dashes, amber, quiet
    for (x, w) in [(CGFloat(232), CGFloat(120)), (CGFloat(392), CGFloat(280)), (CGFloat(712), CGFloat(80))] {
        let d = NSBezierPath(roundedRect: NSRect(x: x*s, y: 512*s, width: w*s, height: 14*s),
                             xRadius: 7*s, yRadius: 7*s)
        amber.withAlphaComponent(0.42).setFill()
        d.fill()
    }

    // live prompt: chevron + block cursor with a phosphor glow
    let glow = NSShadow()
    glow.shadowColor = amber.withAlphaComponent(0.55)
    glow.shadowBlurRadius = 34*s
    glow.set()

    let chevron = NSBezierPath()
    chevron.move(to: NSPoint(x: 260*s, y: 428*s))
    chevron.line(to: NSPoint(x: 420*s, y: 313*s))
    chevron.line(to: NSPoint(x: 260*s, y: 198*s))
    chevron.lineWidth = 64*s
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    amber.setStroke()
    chevron.stroke()

    let cursor = NSBezierPath(roundedRect: NSRect(x: 500*s, y: 208*s, width: 128*s, height: 210*s),
                              xRadius: 14*s, yRadius: 14*s)
    amberHot.setFill()
    cursor.fill()

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
let sizes: [(Int, String)] = [
    (16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png"),
]
for (px, name) in sizes {
    let rep = render(px)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(outDir)/\(name)"))
}
print("wrote \(sizes.count) pngs to \(outDir)")
