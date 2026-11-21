import AppKit
import ImageIO
import UniformTypeIdentifiers

// Icon Composer builds the iOS icon. This produces the fallback for the SwiftPM Mac app.
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appending(path: "Resources")
let layers = resources.appending(path: "AppIcon.icon/Assets")
let size = 1024
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let gradient = CGGradient(colorsSpace: nil, colors: [
    CGColor(srgbRed: 0.90196, green: 0.92157, blue: 0.94902, alpha: 1),
    CGColor(srgbRed: 0.99608, green: 0.98824, blue: 0.96863, alpha: 1)
] as CFArray, locations: nil)!
context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
for name in ["calendar-rule", "calendar-date"] {
    let image = NSImage(contentsOf: layers.appending(path: "\(name).svg"))!
    image.draw(in: CGRect(x: 0, y: 0, width: size, height: size))
}
NSGraphicsContext.restoreGraphicsState()

let png = NSMutableData()
let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
precondition(CGImageDestinationFinalize(destination))

func length(_ count: Int) -> Data {
    var integer = UInt32(count).bigEndian
    return withUnsafeBytes(of: &integer) { Data($0) }
}

// The modern ic10 representation embeds the 1024 px PNG directly.
var icon = Data("icns".utf8) + length(16 + png.length)
icon += Data("ic10".utf8) + length(8 + png.length) + (png as Data)
try icon.write(to: resources.appending(path: "Stillday.icns"))
