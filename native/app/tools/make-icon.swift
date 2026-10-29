// Draws native/app/icon.png, the 1024 px source of the app icon: a dark charcoal
// rounded square with a red dot over a white three-bar waveform. Run once by hand
// when the design changes; the build only needs the png.
//   swiftc -o /tmp/make-icon native/app/tools/make-icon.swift && /tmp/make-icon native/app/icon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write("usage: make-icon <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: CommandLine.arguments[1])

let space = CGColorSpace(name: CGColorSpace.sRGB)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { exit(1) }

func colour(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor { CGColor(colorSpace: space, components: [r, g, b, 1])! }

// The macOS icon grid: an 824 px rounded square centred in 1024, corner radius about 185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
ctx.addPath(CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil))
ctx.setFillColor(colour(0.17, 0.18, 0.19))
ctx.fillPath()

// Three white bars, the middle one tallest, centred a little below the middle.
ctx.setFillColor(colour(1, 1, 1))
let barWidth: CGFloat = 96
let gap: CGFloat = 64
let heights: [CGFloat] = [260, 420, 260]
let centreY: CGFloat = 400
let firstX = CGFloat(size) / 2 - (3 * barWidth + 2 * gap) / 2
for (i, h) in heights.enumerated() {
    let rect = CGRect(x: firstX + CGFloat(i) * (barWidth + gap), y: centreY - h / 2, width: barWidth, height: h)
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
}
ctx.fillPath()

// The red recording dot above the waveform.
ctx.setFillColor(colour(0.93, 0.22, 0.20))
ctx.fillEllipse(in: CGRect(x: CGFloat(size) / 2 - 75, y: 700, width: 150, height: 150))

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
