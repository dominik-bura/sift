import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: generate-icon-composer-layers.swift <output-directory>\n".utf8))
    exit(2)
}

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let canvas = NSRect(x: 0, y: 0, width: 1024, height: 1024)

func writePDF(name: String, color: NSColor, path: NSBezierPath) throws {
    let mutable = NSMutableData()
    var mediaBox = canvas
    guard let consumer = CGDataConsumer(data: mutable as CFMutableData),
          let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
        throw CocoaError(.fileWriteUnknown)
    }
    let graphics = NSGraphicsContext(cgContext: context, flipped: false)
    context.beginPDFPage(nil)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    color.setFill()
    path.fill()
    NSGraphicsContext.restoreGraphicsState()
    context.endPDFPage()
    context.closePDF()
    try mutable.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
}

func writePNG(name: String, draw: () -> Void) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: Int(canvas.width),
        pixelsHigh: Int(canvas.height),
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSColor.clear.setFill()
    canvas.fill()
    draw()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
}

func fill(_ path: NSBezierPath, with color: NSColor) {
    color.setFill()
    path.fill()
}

let bowl = NSBezierPath()
bowl.move(to: NSPoint(x: 222, y: 724))
bowl.curve(to: NSPoint(x: 185, y: 668), controlPoint1: NSPoint(x: 191, y: 724), controlPoint2: NSPoint(x: 172, y: 696))
bowl.curve(to: NSPoint(x: 398, y: 411), controlPoint1: NSPoint(x: 224, y: 585), controlPoint2: NSPoint(x: 302, y: 488))
bowl.curve(to: NSPoint(x: 500, y: 375), controlPoint1: NSPoint(x: 427, y: 388), controlPoint2: NSPoint(x: 463, y: 375))
bowl.line(to: NSPoint(x: 524, y: 375))
bowl.curve(to: NSPoint(x: 626, y: 411), controlPoint1: NSPoint(x: 561, y: 375), controlPoint2: NSPoint(x: 597, y: 388))
bowl.curve(to: NSPoint(x: 839, y: 668), controlPoint1: NSPoint(x: 722, y: 488), controlPoint2: NSPoint(x: 800, y: 585))
bowl.curve(to: NSPoint(x: 802, y: 724), controlPoint1: NSPoint(x: 852, y: 696), controlPoint2: NSPoint(x: 833, y: 724))
bowl.close()

let stem = NSBezierPath()
stem.move(to: NSPoint(x: 396, y: 396))
stem.line(to: NSPoint(x: 628, y: 396))
stem.line(to: NSPoint(x: 575, y: 326))
stem.curve(to: NSPoint(x: 546, y: 247), controlPoint1: NSPoint(x: 558, y: 303), controlPoint2: NSPoint(x: 548, y: 276))
stem.line(to: NSPoint(x: 538, y: 137))
stem.curve(to: NSPoint(x: 507, y: 91), controlPoint1: NSPoint(x: 537, y: 117), controlPoint2: NSPoint(x: 525, y: 100))
stem.curve(to: NSPoint(x: 452, y: 97), controlPoint1: NSPoint(x: 489, y: 83), controlPoint2: NSPoint(x: 468, y: 85))
stem.curve(to: NSPoint(x: 430, y: 138), controlPoint1: NSPoint(x: 439, y: 107), controlPoint2: NSPoint(x: 431, y: 122))
stem.line(to: NSPoint(x: 422, y: 247))
stem.curve(to: NSPoint(x: 393, y: 326), controlPoint1: NSPoint(x: 420, y: 276), controlPoint2: NSPoint(x: 410, y: 303))
stem.line(to: NSPoint(x: 396, y: 396))
stem.close()

let seam = NSBezierPath(roundedRect: NSRect(x: 390, y: 385, width: 244, height: 22), xRadius: 11, yRadius: 11)

let bowlColor = NSColor(calibratedRed: 1.0, green: 0.73, blue: 0.67, alpha: 0.82)
let stemColor = NSColor(calibratedRed: 1.0, green: 0.35, blue: 0.24, alpha: 0.95)
let seamColor = NSColor(calibratedWhite: 1.0, alpha: 0.92)

try writePDF(name: "SiftBowl.pdf", color: bowlColor, path: bowl)
try writePDF(name: "SiftStem.pdf", color: stemColor, path: stem)
try writePDF(name: "SiftSeam.pdf", color: seamColor, path: seam)
try writePNG(name: "SiftBowl.png") { fill(bowl, with: bowlColor) }
try writePNG(name: "SiftStem.png") { fill(stem, with: stemColor) }
try writePNG(name: "SiftSeam.png") { fill(seam, with: seamColor) }
try writePNG(name: "SiftBackground.png") {
    let gradient = NSGradient(colors: [
        NSColor(calibratedWhite: 1.0, alpha: 1.0),
        NSColor(calibratedRed: 0.96, green: 0.95, blue: 0.94, alpha: 1.0),
    ])!
    gradient.draw(in: canvas, angle: -90)
}
