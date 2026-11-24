// Renders an SF Symbol onto a rounded-rect tile and writes a complete .iconset directory.
// usage: swift make-icons.swift <symbol-name> <out.iconset> [hex-color]
import AppKit

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: make-icons.swift <symbol> <out.iconset> [rrggbb]\n".utf8))
    exit(64)
}
let symbolName = args[1]
let outDir = URL(fileURLWithPath: args[2], isDirectory: true)
let hex = args.count > 3 ? args[3] : "2f6fed"
let value = UInt32(hex, radix: 16) ?? 0x2f6fed
let tile = NSColor(srgbRed: CGFloat((value >> 16) & 0xff) / 255, green: CGFloat((value >> 8) & 0xff) / 255,
                   blue: CGFloat(value & 0xff) / 255, alpha: 1)

guard NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) != nil else {
    FileHandle.standardError.write(Data("unknown SF Symbol: \(symbolName)\n".utf8))
    exit(2)
}

func render(pixels: Int) -> Data? {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                     samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: pixels, height: pixels)
    guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    let s = CGFloat(pixels)
    let inset = s * 0.06
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    tile.setFill()
    NSBezierPath(roundedRect: rect, xRadius: s * 0.22, yRadius: s * 0.22).fill()
    let config = NSImage.SymbolConfiguration(pointSize: s * 0.5, weight: .regular)
        .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
    if let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
        let size = symbol.size
        let scale = min(rect.width * 0.62 / size.width, rect.height * 0.62 / size.height)
        let w = size.width * scale, h = size.height * scale
        symbol.draw(in: NSRect(x: (s - w) / 2, y: (s - h) / 2, width: w, height: h))
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, px) in sizes {
    guard let png = render(pixels: px) else { FileHandle.standardError.write(Data("render failed \(name)\n".utf8)); exit(2) }
    try png.write(to: outDir.appendingPathComponent(name + ".png"))
}
