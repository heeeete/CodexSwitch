import SwiftUI

@main
struct CodexSwitchApp: App {
    @StateObject private var accountStore = AccountStore()

    var body: some Scene {
        // 메뉴바 아이콘을 앱의 유일한 진입점으로 사용한다.
        MenuBarExtra {
            MenuContentView(store: accountStore)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .accessibilityLabel("CodexSwitch")
        }
        .menuBarExtraStyle(.window)
    }
}
