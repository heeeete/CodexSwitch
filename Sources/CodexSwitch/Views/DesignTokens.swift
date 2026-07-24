import SwiftUI

// 신호 전환기 콘셉트의 색과 타이포그래피 토큰을 한곳에 둔다.
enum CodexSwitchDesign {
    static let iris = Color(red: 0.40, green: 0.39, blue: 0.96)
    static let aqua = Color(red: 0.27, green: 0.78, blue: 0.70)
    static let coral = Color(red: 0.96, green: 0.42, blue: 0.34)
    static let amber = Color(red: 0.95, green: 0.66, blue: 0.22)

    static func cardBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.045)
            : Color.black.opacity(0.035)
    }

    static func hairline(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.09)
            : Color.black.opacity(0.08)
    }

    static func hoverBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.075)
            : Color.black.opacity(0.055)
    }

    static func pressedBackground(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? iris.opacity(0.16)
            : iris.opacity(0.10)
    }

    static func secondaryText(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.58)
            : Color.black.opacity(0.64)
    }

    // 작은 보조 문구는 밝은 배경에서도 충분한 명암을 유지한다.
    static func smallText(for scheme: ColorScheme) -> Color {
        scheme == .dark
            ? Color.white.opacity(0.7)
            : Color.black.opacity(0.72)
    }

    // 상태색은 밝은 테마에서 작은 글자에 쓰일 때 더 어두운 변형을 사용한다.
    static func accentText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? iris : Color(red: 0.30, green: 0.28, blue: 0.72)
    }

    static func successText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? aqua : Color(red: 0.04, green: 0.43, blue: 0.36)
    }

    static func warningText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? amber : Color(red: 0.48, green: 0.30, blue: 0.02)
    }

    static func errorText(for scheme: ColorScheme) -> Color {
        scheme == .dark ? coral : Color(red: 0.69, green: 0.18, blue: 0.13)
    }
}
