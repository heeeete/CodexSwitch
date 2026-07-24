import AppKit
import SwiftUI

// 앱 번들의 아이콘을 그대로 쓰고 SwiftPM 실행에서는 같은 벡터 마크를 그린다.
@MainActor
enum CodexSwitchIcon {
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

// 메뉴바와 헤더가 같은 앱 아이콘 렌더링을 공유한다.
struct CodexSwitchIconView: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: CodexSwitchIcon.image)
            .resizable()
            .interpolation(.high)
            .frame(width: size, height: size)
    }
}
