import AppKit

@main
struct CodexSwitchApp {
    // NSMenu와 설정 창을 AppKit 한 경로에서 소유해 별도의 SwiftUI 설정 창을 만들지 않는다.
    @MainActor
    static func main() {
        // dyld의 Sparkle 로딩까지 검증하되 계정 조회나 설치는 시작하지 않는다.
        if CommandLine.arguments.contains("--verify-launch") {
            // 설치된 번들 안에서 두 언어를 실제로 읽을 수 있는지도 함께 확인한다.
            for (language, expected) in [("ko", "설정…"), ("en", "Settings…")] {
                guard let path = L10n.resources.path(forResource: language, ofType: "lproj"),
                      let bundle = Bundle(path: path),
                      bundle.localizedString(forKey: "설정…", value: nil, table: nil) == expected else {
                    fatalError("Missing or invalid localization: \(language)")
                }
            }
            print("CodexSwitch launch verification passed")
            return
        }
        let application = NSApplication.shared
        let startup = AppStartup()
        application.delegate = startup
        application.setActivationPolicy(.accessory)
        withExtendedLifetime(startup) {
            application.run()
        }
    }
}
