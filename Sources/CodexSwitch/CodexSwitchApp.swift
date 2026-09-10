import SwiftUI

@main
struct CodexSwitchApp: App {
    @StateObject private var accountStore: AccountStore
    @StateObject private var updateStore: UpdateStore

    // 업데이트 확인은 메뉴를 열기 전부터 시작하고 계정 작업과 재시작 상태를 함께 보호한다.
    init() {
        let accounts = AccountStore()
        _accountStore = StateObject(wrappedValue: accounts)
        let updates = UpdateStore(
            startAutomatically: true,
            prepareForRestart: { accounts.prepareForUpdateRestart() },
            restartCancelled: { accounts.cancelUpdateRestart() }
        )
        _updateStore = StateObject(wrappedValue: updates)
    }

    var body: some Scene {
        // 메뉴바 아이콘을 앱의 유일한 진입점으로 사용한다.
        MenuBarExtra {
            MenuContentView(store: accountStore, updateStore: updateStore)
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .accessibilityLabel("CodexSwitch")
        }
        .menuBarExtraStyle(.window)

        // 메뉴의 설정 행에서 여는 macOS 기본 설정 창이다.
        Settings {
            SettingsView(updateStore: updateStore, accountStore: accountStore)
        }
        .windowResizability(.contentSize)
    }
}
