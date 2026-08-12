import AppKit
import Foundation

guard CommandLine.arguments.count == 4 else {
    fatalError("Usage: compare-sift-icons.swift <app-icon.png> <menu-icon.svg> <comparison.png>")
}

let appIconURL = URL(fileURLWithPath: CommandLine.arguments[1])
let menuIconURL = URL(fileURLWithPath: CommandLine.arguments[2])
let outputURL = URL(fileURLWithPath: CommandLine.arguments[3])
guard let appIcon = NSImage(contentsOf: appIconURL),
      let menuIcon = NSImage(contentsOf: menuIconURL),
      let tiff = appIcon.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff) else {
    fatalError("Could not read icon assets")
}

var minX = bitmap.pixelsWide
var minY = bitmap.pixelsHigh
var maxX = 0
var maxY = 0
var extents: [Int: (left: Int, right: Int)] = [:]
for y in 0..<bitmap.pixelsHigh {
    for x in 0..<bitmap.pixelsWide {
        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
        if color.redComponent > 0.68,
           color.redComponent - color.greenComponent > 0.055,
           color.redComponent - color.blueComponent > 0.075 {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
            if let current = extents[y] {
                extents[y] = (min(current.left, x), max(current.right, x))
            } else {
                extents[y] = (x, x)
            }
        }
    }
}

let outputSize = 720
let output = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: outputSize,
    pixelsHigh: outputSize,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
NSColor.white.setFill()
NSRect(x: 0, y: 0, width: outputSize, height: outputSize).fill()

let markWidth = maxX - minX + 1
let markHeight = maxY - minY + 1
let comparisonPadding = Int(Double(max(markWidth, markHeight)) * 1.25 / 15.5)
let sourceRect = NSRect(
    x: minX - comparisonPadding,
    y: minY - comparisonPadding,
    width: markWidth + comparisonPadding * 2,
    height: markHeight + comparisonPadding * 2
)
let targetRect = NSRect(x: 50, y: 50, width: 620, height: 620)
let sourceMinX = Int(sourceRect.minX)
let sourceMinY = Int(sourceRect.minY)
for targetY in 50..<670 {
    for targetX in 50..<670 {
        let u = Double(targetX - 50) / 619.0
        let v = Double(targetY - 50) / 619.0
        let sourceX = sourceMinX + Int(u * Double(Int(sourceRect.width) - 1))
        let sourceY = sourceMinY + Int(v * Double(Int(sourceRect.height) - 1))
        if sourceX >= 0, sourceX < bitmap.pixelsWide,
           sourceY >= 0, sourceY < bitmap.pixelsHigh,
           let color = bitmap.colorAt(x: sourceX, y: sourceY) {
            output.setColor(color, atX: targetX, y: targetY)
        }
    }
}

// Black at 52% opacity is the current menu SVG over the real orange funnel.
menuIcon.draw(in: targetRect, from: .zero, operation: .sourceOver, fraction: 0.52)
NSGraphicsContext.restoreGraphicsState()

try output.representation(using: .png, properties: [:])!.write(to: outputURL)
print("Actual funnel bounds: x=\(minX)...\(maxX), y=\(minY)...\(maxY)")
for y in stride(from: minY, through: maxY, by: 32) {
    if let extent = extents[y] {
        print("row \(y): \(extent.left)...\(extent.right)")
    }
}
