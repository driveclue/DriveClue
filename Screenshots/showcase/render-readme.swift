// Builds the README gallery images: each showcase card is scaled down, given
// rounded corners and a soft drop shadow, and padded with transparent space.
// GitHub strips CSS from READMEs, so spacing and shadows must live in the PNGs.
//
// Usage (from this folder): swift render-readme.swift
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let files = [
    "01-dashboard",
    "02-health-indicators",
    "03-device-statistics",
    "04-disk-speed-test",
    "05-storage-analyzer",
]

let cardWidth: CGFloat = 1280
let cardHeight: CGFloat = 800
let cornerRadius: CGFloat = 22
let padding: CGFloat = 44
let shadowBlur: CGFloat = 30
let shadowOffsetY: CGFloat = 12

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let outputDir = root.appendingPathComponent("readme")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Cannot read \(url.path)")
    }
    return image
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, UTType.png.identifier as CFString, 1, nil
    ) else { fatalError("Cannot write \(url.path)") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Cannot finalize \(url.path)") }
}

for name in files {
    let card = loadImage(root.appendingPathComponent("\(name).png"))
    let width = Int(cardWidth + padding * 2)
    let height = Int(cardHeight + padding * 2)
    guard let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Cannot create context") }
    ctx.interpolationQuality = .high

    // Core Graphics is bottom-left origin, so a downward shadow has negative y.
    let rect = CGRect(x: padding, y: padding, width: cardWidth, height: cardHeight)
    let path = CGPath(roundedRect: rect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

    ctx.saveGState()
    ctx.setShadow(
        offset: CGSize(width: 0, height: -shadowOffsetY), blur: shadowBlur,
        color: CGColor(red: 0.06, green: 0.1, blue: 0.16, alpha: 0.32)
    )
    ctx.addPath(path)
    ctx.setFillColor(CGColor(gray: 0.94, alpha: 1))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    ctx.draw(card, in: rect)
    ctx.restoreGState()

    // Hairline edge so the card stays defined on light backgrounds.
    ctx.addPath(CGPath(
        roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
        cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil
    ))
    ctx.setStrokeColor(CGColor(red: 0.17, green: 0.2, blue: 0.24, alpha: 0.12))
    ctx.setLineWidth(1)
    ctx.strokePath()

    guard let output = ctx.makeImage() else { fatalError("Cannot render \(name)") }
    let url = outputDir.appendingPathComponent("\(name).png")
    writePNG(output, to: url)
    print("\(url.lastPathComponent) \(width)x\(height)")
}
