#!/usr/bin/env swift

import AppKit
import Foundation

// iconset에 필요한 모든 배율의 PNG를 동일한 벡터 드로잉으로 만든다.
let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "CodexSwitch.iconset")
try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

let iconFiles: [(name: String, pixels: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for iconFile in iconFiles {
    let size = CGFloat(iconFile.pixels)
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: iconFile.pixels,
        pixelsHigh: iconFile.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let graphicsContext = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("Unable to create \(iconFile.name) bitmap")
    }
    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphicsContext
    defer { NSGraphicsContext.restoreGraphicsState() }
    let context = graphicsContext.cgContext

    // 둥근 사각형 안에 아이리스-아쿠아 신호 그라디언트를 넣는다.
    let inset = size * 0.055
    let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = size * 0.225
    let shape = CGPath(
        roundedRect: rect,
        cornerWidth: radius,
        cornerHeight: radius,
        transform: nil
    )
    context.saveGState()
    context.addPath(shape)
    context.clip()

    let colors = [
        NSColor(red: 0.34, green: 0.32, blue: 0.94, alpha: 1).cgColor,
        NSColor(red: 0.22, green: 0.79, blue: 0.70, alpha: 1).cgColor
    ] as CFArray
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let gradient = CGGradient(colorsSpace: colorSpace, colors: colors, locations: [0, 1])!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: rect.minX, y: rect.maxY),
        end: CGPoint(x: rect.maxX, y: rect.minY),
        options: []
    )
    context.restoreGState()

    // 두 계정 노드와 교차 라우트로 전환 동작을 나타낸다.
    context.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
    context.setLineWidth(size * 0.065)
    context.setLineCap(.round)
    context.move(to: CGPoint(x: size * 0.29, y: size * 0.35))
    context.addCurve(
        to: CGPoint(x: size * 0.71, y: size * 0.65),
        control1: CGPoint(x: size * 0.48, y: size * 0.35),
        control2: CGPoint(x: size * 0.52, y: size * 0.65)
    )
    context.strokePath()

    context.move(to: CGPoint(x: size * 0.29, y: size * 0.65))
    context.addCurve(
        to: CGPoint(x: size * 0.71, y: size * 0.35),
        control1: CGPoint(x: size * 0.48, y: size * 0.65),
        control2: CGPoint(x: size * 0.52, y: size * 0.35)
    )
    context.strokePath()

    for point in [
        CGPoint(x: size * 0.27, y: size * 0.35),
        CGPoint(x: size * 0.27, y: size * 0.65),
        CGPoint(x: size * 0.73, y: size * 0.35),
        CGPoint(x: size * 0.73, y: size * 0.65)
    ] {
        let nodeSize = size * 0.13
        let nodeRect = CGRect(
            x: point.x - nodeSize / 2,
            y: point.y - nodeSize / 2,
            width: nodeSize,
            height: nodeSize
        )
        context.setFillColor(NSColor.white.cgColor)
        context.fillEllipse(in: nodeRect)
    }

    guard let png = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("Unable to encode \(iconFile.name)")
    }

    try png.write(to: outputDirectory.appendingPathComponent(iconFile.name))
}
