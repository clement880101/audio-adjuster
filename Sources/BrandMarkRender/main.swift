import BrandMark
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Writes the .iconset ladder that `iconutil` turns into AudioAdjuster.icns. There is no
// SVG rasteriser on a stock macOS box, and adding one would put a Homebrew dependency in
// front of `make app` for a repo that otherwise needs nothing but a Swift toolchain — so
// the icon is drawn rather than converted.

/// The names macOS requires, paired with the pixel size each one must actually be. The
/// two entries that share a size are written from the same render.
let rungs: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("BrandMarkRender: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 3 else {
    fail("usage: BrandMarkRender <output.iconset> <glyph-directory>")
}
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let glyphDirectory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

for directory in [outputDirectory, glyphDirectory] {
    do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
        fail("could not create \(directory.path): \(error.localizedDescription)")
    }
}

func write(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        fail("could not write \(url.path)")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fail("could not finalize \(url.path)") }
}

func render(pixels: Int) -> CGImage {
    let space = CGColorSpaceCreateDeviceRGB()
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not open a \(pixels)px drawing context")
    }
    context.setAllowsAntialiasing(true)
    BrandMark.drawAppIcon(in: context, size: CGFloat(pixels))
    guard let image = context.makeImage() else { fail("could not render at \(pixels)px") }
    return image
}

// Renders shared by two rungs are drawn once, so the pair cannot drift apart.
var renders: [Int: CGImage] = [:]
for rung in rungs {
    let image = renders[rung.pixels] ?? render(pixels: rung.pixels)
    renders[rung.pixels] = image

    write(image, to: outputDirectory.appendingPathComponent(rung.name))
}

// The menu bar glyph ships as a bundle resource rather than as a SwiftUI label view:
// MenuBarExtra's `image:` initialiser reliably produces a status item, where a custom
// `label:` closure produced none at all on macOS 26. The "Template" suffix is load
// bearing — NSImage(named:) reads it and sets isTemplate, which is what lets macOS
// invert the glyph for a light or dark menu bar.
func renderGlyph(pixels: Int) -> CGImage {
    guard let context = CGContext(data: nil, width: pixels, height: pixels,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
        fail("could not open a \(pixels)px glyph context")
    }
    let ink = CGColor(gray: 0, alpha: 1)
    BrandMark.draw(in: context,
                   rect: CGRect(x: 0, y: 0, width: CGFloat(pixels), height: CGFloat(pixels)),
                   form: .reduced, color: ink, trackColor: ink)
    guard let image = context.makeImage() else { fail("could not render the \(pixels)px glyph") }
    return image
}

write(renderGlyph(pixels: 18), to: glyphDirectory.appendingPathComponent("MenuBarGlyphTemplate.png"))
write(renderGlyph(pixels: 36), to: glyphDirectory.appendingPathComponent("MenuBarGlyphTemplate@2x.png"))

print("wrote \(rungs.count) icons to \(outputDirectory.path)")
print("wrote the menu bar glyph to \(glyphDirectory.path)")
