#!/usr/bin/env swift
// Generate App/AppIcon.icns from an SF Symbol over a blue gradient squircle.
// Re-run whenever the design changes; the resulting .icns is committed.
import AppKit
import Foundation

let outDir = CommandLine.arguments.dropFirst().first ?? "App"
let iconset = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.iconset")
let icns = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.icns")

try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px, pixelsHigh: px,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
        isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 32
    )!

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    let rect = NSRect(x: 0, y: 0, width: s, height: s)
    let path = NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22)

    let gradient = NSGradient(colors: [
        NSColor(srgbRed: 0.75, green: 0.86, blue: 0.95, alpha: 1.0),
        NSColor(srgbRed: 0.55, green: 0.72, blue: 0.88, alpha: 1.0),
    ])!
    gradient.draw(in: path, angle: -90)

    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.55, weight: .semibold)
        .applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "speaker.wave.2.fill", accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) {
        let w = sym.size.width
        let h = sym.size.height
        let dx = (s - w) / 2
        // Tiny optical nudge left — the speaker + waves feel right-heavy.
        let drawRect = NSRect(x: dx - s * 0.02, y: (s - h) / 2, width: w, height: h)
        sym.draw(in: drawRect)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

func writePNG(_ rep: NSBitmapImageRep, to url: URL) throws {
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try data.write(to: url)
}

let sizes: [(String, Int)] = [
    ("icon_16x16.png",       16),
    ("icon_16x16@2x.png",    32),
    ("icon_32x32.png",       32),
    ("icon_32x32@2x.png",    64),
    ("icon_128x128.png",     128),
    ("icon_128x128@2x.png",  256),
    ("icon_256x256.png",     256),
    ("icon_256x256@2x.png",  512),
    ("icon_512x512.png",     512),
    ("icon_512x512@2x.png",  1024),
]

for (name, px) in sizes {
    try writePNG(render(px: px), to: iconset.appendingPathComponent(name))
    print("→ \(name) (\(px)×\(px))")
}

// Standalone 512px PNG for README display (GitHub doesn't render .icns).
let previewPath = URL(fileURLWithPath: outDir).appendingPathComponent("AppIcon.png")
try writePNG(render(px: 512), to: previewPath)
print("→ wrote \(previewPath.path)")

let proc = Process()
proc.launchPath = "/usr/bin/iconutil"
proc.arguments = ["-c", "icns", iconset.path, "-o", icns.path]
try proc.run()
proc.waitUntilExit()
guard proc.terminationStatus == 0 else {
    print("iconutil failed: \(proc.terminationStatus)")
    exit(proc.terminationStatus)
}

try? FileManager.default.removeItem(at: iconset)
print("→ wrote \(icns.path)")
