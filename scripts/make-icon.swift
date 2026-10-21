// Draws Tide's app icon (1024×1024): a deep-sea gradient, three waves and a
// chevron pair. Run: swift scripts/make-icon.swift App/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon.png"
let space = CGColorSpace(name: CGColorSpace.sRGB)!
// No alpha channel: App Store Connect rejects app icons that have one, even fully opaque.
let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
let s = CGFloat(size)

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// Background: navy to teal, top to bottom.
let background = CGGradient(colorsSpace: space, colors: [color(0x0B1220), color(0x0F2A44), color(0x0F766E)] as CFArray, locations: [0, 0.55, 1])!
context.drawLinearGradient(background, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

// Waves along the bottom third.
for (index, (alpha, offset)) in [(0.55, 0.0), (0.35, 70.0), (0.22, 140.0)].enumerated() {
    let path = CGMutablePath()
    let baseline = s * 0.30 - CGFloat(offset)
    path.move(to: CGPoint(x: 0, y: 0))
    path.addLine(to: CGPoint(x: 0, y: baseline))
    let amplitude: CGFloat = 46 - CGFloat(index) * 8
    let wavelength = s / 2.2
    var x: CGFloat = 0
    while x <= s {
        let y = baseline + sin((x / wavelength) * .pi * 2 + CGFloat(index)) * amplitude
        path.addLine(to: CGPoint(x: x, y: y))
        x += 4
    }
    path.addLine(to: CGPoint(x: s, y: 0))
    path.closeSubpath()
    context.addPath(path)
    context.setFillColor(color(0x5EEAD4, alpha))
    context.fillPath()
}

// Chevrons: < >
context.setStrokeColor(color(0xF1F5F9))
context.setLineWidth(70)
context.setLineCap(.round)
context.setLineJoin(.round)
let center = CGPoint(x: s / 2, y: s * 0.60)
let arm: CGFloat = 150
context.move(to: CGPoint(x: center.x - 120, y: center.y + arm))
context.addLine(to: CGPoint(x: center.x - 270, y: center.y))
context.addLine(to: CGPoint(x: center.x - 120, y: center.y - arm))
context.move(to: CGPoint(x: center.x + 120, y: center.y + arm))
context.addLine(to: CGPoint(x: center.x + 270, y: center.y))
context.addLine(to: CGPoint(x: center.x + 120, y: center.y - arm))
context.strokePath()
// The slash, in the accent color.
context.setStrokeColor(color(0x2DD4BF))
context.move(to: CGPoint(x: center.x + 50, y: center.y + 190))
context.addLine(to: CGPoint(x: center.x - 50, y: center.y - 190))
context.strokePath()

let image = context.makeImage()!
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: output) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(output)")
