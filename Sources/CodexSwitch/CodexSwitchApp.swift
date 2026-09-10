import SwiftUI

@main
struct CodexSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppStartup.self) private var startup

    var body: some Scene {
        CodexSwitchScenes(startup: startup)
    }
}

// AppDelegateAdaptor는 상태 변경을 Scene에 전달하지 않으므로 Scene이 직접 관찰한다.
struct CodexSwitchScenes: Scene {
    @ObservedObject var startup: AppStartup

    var body: some Scene {
        // 메뉴바 아이콘을 앱의 유일한 진입점으로 사용한다.
        MenuBarExtra(isInserted: .constant(startup.isReady)) {
            if startup.isReady {
                MenuContentView(store: startup.accountStore, updateStore: startup.updateStore)
            }
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .accessibilityLabel("CodexSwitch")
        }
        .menuBarExtraStyle(.window)

        // 메뉴의 설정 행에서 여는 macOS 기본 설정 창이다.
        Settings {
            if startup.isReady {
                SettingsView(updateStore: startup.updateStore, accountStore: startup.accountStore)
            }
        }
        .windowResizability(.contentSize)
    }
}
