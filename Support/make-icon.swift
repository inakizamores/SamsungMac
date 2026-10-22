// Generates Support/AppIcon.icns and docs/icon.png.
// Run from the repo root:  swift Support/make-icon.swift
import AppKit

func render(pixels: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil,
                               pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let s = CGFloat(pixels)
    // Apple icon grid: squircle occupies 824/1024 of the canvas.
    let margin = s * 100.0 / 1024.0
    let rect = NSRect(x: margin, y: margin, width: s - 2 * margin, height: s - 2 * margin)
    let radius = rect.width * 0.2237

    let squircle = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
    NSGraphicsContext.current?.saveGraphicsState()
    squircle.addClip()
    NSGradient(starting: NSColor(calibratedWhite: 0.20, alpha: 1),
               ending: NSColor(calibratedWhite: 0.06, alpha: 1))!
        .draw(in: rect, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    if let sym = NSImage(systemSymbolName: "tv", accessibilityDescription: nil) {
        let config = NSImage.SymbolConfiguration(pointSize: rect.width * 0.42, weight: .regular)
        if let configured = sym.withSymbolConfiguration(config) {
            let symSize = configured.size
            let tinted = NSImage(size: symSize)
            tinted.lockFocus()
            configured.draw(in: NSRect(origin: .zero, size: symSize))
            NSColor.white.set()
            NSRect(origin: .zero, size: symSize).fill(using: .sourceAtop)
            tinted.unlockFocus()
            let origin = NSPoint(x: rect.midX - symSize.width / 2,
                                 y: rect.midY - symSize.height / 2)
            tinted.draw(in: NSRect(origin: origin, size: symSize))
        }
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to path: String) {
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let fm = FileManager.default
let iconset = "build/AppIcon.iconset"
try? fm.removeItem(atPath: iconset)
try! fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
try? fm.createDirectory(atPath: "docs", withIntermediateDirectories: true)

let entries: [(Int, String)] = [
    (16, "icon_16x16"), (32, "icon_16x16@2x"),
    (32, "icon_32x32"), (64, "icon_32x32@2x"),
    (128, "icon_128x128"), (256, "icon_128x128@2x"),
    (256, "icon_256x256"), (512, "icon_256x256@2x"),
    (512, "icon_512x512"), (1024, "icon_512x512@2x"),
]
for (px, name) in entries {
    writePNG(render(pixels: px), to: "\(iconset)/\(name).png")
}
writePNG(render(pixels: 512), to: "docs/icon.png")

let task = Process()
task.launchPath = "/usr/bin/iconutil"
task.arguments = ["-c", "icns", iconset, "-o", "Support/AppIcon.icns"]
task.launch()
task.waitUntilExit()
print(task.terminationStatus == 0 ? "AppIcon.icns + docs/icon.png generated" : "iconutil failed")
