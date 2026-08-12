import AppKit
import Foundation

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-icon-assets.swift <asset-directory>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func funnelPath(scale: CGFloat) -> NSBezierPath {
    func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * scale, y: y * scale) }

    let path = NSBezierPath()
    path.move(to: point(2.4, 13.8))
    path.curve(to: point(5.9, 9.0), controlPoint1: point(2.4, 12.6), controlPoint2: point(4.5, 10.2))
    path.curve(to: point(7.0, 6.7), controlPoint1: point(6.5, 8.4), controlPoint2: point(6.9, 7.6))
    path.line(to: point(7.5, 3.6))
    path.curve(to: point(9.0, 2.2), controlPoint1: point(7.6, 2.7), controlPoint2: point(8.2, 2.2))
    path.curve(to: point(10.5, 3.6), controlPoint1: point(9.8, 2.2), controlPoint2: point(10.4, 2.7))
    path.line(to: point(11.0, 6.7))
    path.curve(to: point(12.1, 9.0), controlPoint1: point(11.1, 7.6), controlPoint2: point(11.5, 8.4))
    path.curve(to: point(15.6, 13.8), controlPoint1: point(13.5, 10.2), controlPoint2: point(15.6, 12.6))
    path.curve(to: point(14.2, 15.5), controlPoint1: point(15.6, 14.8), controlPoint2: point(15.0, 15.5))
    path.line(to: point(3.8, 15.5))
    path.curve(to: point(2.4, 13.8), controlPoint1: point(3.0, 15.5), controlPoint2: point(2.4, 14.8))
    path.close()
    return path
}

func writeTemplate(scale: CGFloat, suffix: String) throws {
    let pixels = Int(18 * scale)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw CocoaError(.fileWriteUnknown) }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()
    NSColor.black.setFill()
    funnelPath(scale: scale).fill()
    NSGraphicsContext.restoreGraphicsState()

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: outputDirectory.appendingPathComponent("SiftMenuBarIconTemplate\(suffix).png"), options: .atomic)
}

try writeTemplate(scale: 1, suffix: "")
try writeTemplate(scale: 2, suffix: "@2x")
try writeTemplate(scale: 3, suffix: "@3x")
