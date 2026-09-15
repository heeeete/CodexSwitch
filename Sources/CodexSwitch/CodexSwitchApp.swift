import AppKit

@main
struct CodexSwitchApp {
    // NSMenu와 설정 창을 AppKit 한 경로에서 소유해 별도의 SwiftUI 설정 창을 만들지 않는다.
    @MainActor
    static func main() {
        // dyld의 Sparkle 로딩까지 검증하되 계정 조회나 설치는 시작하지 않는다.
        if CommandLine.arguments.contains("--verify-launch") {
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
