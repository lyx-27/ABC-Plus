// Renders the menu-bar icon: "A+", the system's "A" for English plus what this input method adds.
// It is a template image, so macOS tints it for light/dark menu bars.
// Usage: swift make_icon.swift <out.tiff>
import AppKit

func rep(_ px: Int) -> NSBitmapImageRep {
    let r = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    r.size = NSSize(width: 16, height: 16)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: r)
    let s = NSMutableAttributedString(string: "A", attributes: [
        .font: NSFont.systemFont(ofSize: 12.5, weight: .bold), .foregroundColor: NSColor.black,
    ])
    s.append(NSAttributedString(string: "+", attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .heavy), .foregroundColor: NSColor.black,
        .baselineOffset: 1.5,
    ]))
    let size = s.size()
    s.draw(at: NSPoint(x: ((16 - size.width) / 2).rounded(), y: ((16 - size.height) / 2).rounded()))
    NSGraphicsContext.restoreGraphicsState()
    return r
}

let img = NSImage(size: NSSize(width: 16, height: 16))
img.addRepresentation(rep(16))
img.addRepresentation(rep(32))
try! img.tiffRepresentation!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
