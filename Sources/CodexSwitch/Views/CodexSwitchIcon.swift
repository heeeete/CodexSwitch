import AppKit
import SwiftUI

// 앱 번들의 아이콘을 그대로 쓰고 SwiftPM 실행에서는 같은 벡터 마크를 그린다.
@MainActor
enum CodexSwitchIcon {
    // 메뉴바에서는 앱의 교차 곡선만 template 이미지로 그려 시스템 명암에 맞춘다.
    static let menuBarImage: NSImage = {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            defer { context.restoreGState() }
            // 앱 아이콘의 바탕 여백을 걷어내 18pt 안에서 같은 마크를 선명하게 확대한 것이다.
            context.translateBy(x: -5.4, y: -5.4)
            context.scaleBy(x: 28.8, y: 28.8)
            context.setStrokeColor(NSColor.black.cgColor)
            context.setFillColor(NSColor.black.cgColor)
            context.setLineWidth(0.065)
            context.setLineCap(.round)
            context.move(to: CGPoint(x: 0.29, y: 0.35))
            context.addCurve(to: CGPoint(x: 0.71, y: 0.65),
                             control1: CGPoint(x: 0.48, y: 0.35), control2: CGPoint(x: 0.52, y: 0.65))
            context.strokePath()
            context.move(to: CGPoint(x: 0.29, y: 0.65))
            context.addCurve(to: CGPoint(x: 0.71, y: 0.35),
                             control1: CGPoint(x: 0.48, y: 0.65), control2: CGPoint(x: 0.52, y: 0.35))
            context.strokePath()
            for point in [CGPoint(x: 0.27, y: 0.35), CGPoint(x: 0.27, y: 0.65),
                          CGPoint(x: 0.73, y: 0.35), CGPoint(x: 0.73, y: 0.65)] {
                context.fillEllipse(in: CGRect(x: point.x - 0.065, y: point.y - 0.065, width: 0.13, height: 0.13))
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "CodexSwitch"
        return image
    }()

    static let image: NSImage = {
        if let iconURL = Bundle.main.url(forResource: "CodexSwitch", withExtension: "icns"),
           let bundledIcon = NSImage(contentsOf: iconURL) {
            return bundledIcon
        }
        return makeFallbackImage()
    }()

    private static func makeFallbackImage() -> NSImage {
        let size = CGFloat(128)
        return NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            // 앱 아이콘과 같은 아이리스-아쿠아 바탕을 만든다.
            let inset = size * 0.055
            let iconRect = rect.insetBy(dx: inset, dy: inset)
            let shape = CGPath(
                roundedRect: iconRect,
                cornerWidth: size * 0.225,
                cornerHeight: size * 0.225,
                transform: nil
            )
            context.saveGState()
            context.addPath(shape)
            context.clip()
            let colors = [
                NSColor(red: 0.34, green: 0.32, blue: 0.94, alpha: 1).cgColor,
                NSColor(red: 0.22, green: 0.79, blue: 0.70, alpha: 1).cgColor
            ] as CFArray
            let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: colors,
                locations: [0, 1]
            )!
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: iconRect.minX, y: iconRect.maxY),
                end: CGPoint(x: iconRect.maxX, y: iconRect.minY),
                options: []
            )
            context.restoreGState()

            // 두 계정 경로와 네 노드를 작은 크기에서도 선명하게 유지한다.
            context.setStrokeColor(NSColor.white.withAlphaComponent(0.94).cgColor)
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
                context.setFillColor(NSColor.white.cgColor)
                context.fillEllipse(in: CGRect(
                    x: point.x - nodeSize / 2,
                    y: point.y - nodeSize / 2,
                    width: nodeSize,
                    height: nodeSize
                ))
            }
            return true
        }
    }
}

// 헤더는 앱 번들과 같은 컬러 아이콘을 사용한다.
struct CodexSwitchIconView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: CodexSwitchIcon.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
