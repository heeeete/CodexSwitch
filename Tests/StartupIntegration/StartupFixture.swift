import AppKit
import SwiftUI

// 실제 App·Scene·AppStartup을 실행하되 계정과 네트워크 작업만 테스트 대역으로 대체한다.
@MainActor final class AccountStore: ObservableObject {
    init() {
        Task {
            try? await Task.sleep(for: .seconds(2))
            // isVisible만으로는 화면 밖에 남은 미삽입 상태바 창을 구분할 수 없다.
            let visibleItems = NSApplication.shared.windows.filter {
                guard $0.level == .statusBar, $0.isVisible, let screen = $0.screen else { return false }
                return $0.frame.intersects(screen.frame)
            }
            guard !visibleItems.isEmpty else {
                for window in NSApplication.shared.windows {
                    print("Window level=\(window.level.rawValue) visible=\(window.isVisible) screen=\(window.screen != nil) activeSpace=\(window.isOnActiveSpace) frame=\(window.frame)")
                }
                print("FAIL: startup completed without a menu bar item on screen")
                exit(EXIT_FAILURE)
            }
            print("PASS: startup displayed a menu bar item on screen")
            NSApp.terminate(nil)
        }
    }

    func prepareForUpdateRestart() -> Bool { true }
    func cancelUpdateRestart() {}
}

// 테스트에서는 Sparkle나 실제 계정을 시작하지 않으며 Scene의 생성 경로를 유지한다.
@MainActor final class UpdateStore: ObservableObject {
    init(startAutomatically: Bool, prepareForRestart: @escaping () -> Bool, restartCancelled: @escaping () -> Void) {}
}

struct MenuContentView: View {
    let store: AccountStore
    let updateStore: UpdateStore
    var body: some View { Text("Startup test") }
}

struct SettingsView: View {
    let updateStore: UpdateStore
    let accountStore: AccountStore
    var body: some View { Text("Startup test settings") }
}

struct InstallationView: View {
    let startup: AppStartup
    var body: some View { Text("Startup test installation") }
}
