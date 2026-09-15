import AppKit
import XCTest
@testable import CodexSwitch

@MainActor
final class StatusMenuControllerTests: XCTestCase {
    // 작업 중 열었던 메뉴에서도 작업 종료 후 단축키가 살아 있고 설정 창은 재사용한다.
    func testCommandsUseCurrentStateAndReuseSettingsWindow() async throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let suite = "StatusMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoRefreshEnabled")
        let store = AccountStore(userDefaults: defaults, resetCreditLoader: { _ in [] })
        store.applyPreviewRegistry(.empty)
        let updates = UpdateStore()
        let controller = StatusMenuController(store: store, updateStore: updates)
        defer {
            controller.stop()
            NSApp.mainMenu = previousMenu
            defaults.removePersistentDomain(forName: suite)
        }
        XCTAssertTrue(store.prepareForUpdateRestart())
        controller.menuWillOpen(controller.menu)
        let settingsIndex = try XCTUnwrap(controller.menu.items.firstIndex { $0.keyEquivalent == "," })
        let quitItem = try XCTUnwrap(controller.menu.items.first { $0.keyEquivalent == "q" })
        XCTAssertTrue(controller.menu.item(at: settingsIndex)!.isEnabled)
        XCTAssertTrue(quitItem.isEnabled)
        controller.menu.performActionForItem(at: settingsIndex)
        XCTAssertNil(controller.settingsWindow)

        store.cancelUpdateRestart()
        controller.menu.performActionForItem(at: settingsIndex)
        let firstWindow = try XCTUnwrap(controller.settingsWindow)
        firstWindow.close()
        // 상태바 메뉴와 앱 메뉴가 같은 설정 창 생성 경로를 사용한다.
        let applicationMenu = try XCTUnwrap(NSApp.mainMenu?.items.first?.submenu)
        let appSettingsIndex = try XCTUnwrap(applicationMenu.items.firstIndex { $0.keyEquivalent == "," })
        applicationMenu.performActionForItem(at: appSettingsIndex)
        XCTAssertTrue(firstWindow === controller.settingsWindow)
        XCTAssertTrue(firstWindow.isVisible)
        // 열린 설정에서 업데이트 안내가 추가돼도 창 내부에 모두 들어가야 한다.
        UpdateUserDriver(store: updates).showReady { _ in }
        try await Task.sleep(for: .milliseconds(50))
        firstWindow.contentView?.layoutSubtreeIfNeeded()
        let requiredHeight = try XCTUnwrap(firstWindow.contentView?.fittingSize.height)
        XCTAssertGreaterThanOrEqual(firstWindow.contentLayoutRect.height, requiredHeight)
        controller.menuDidClose(controller.menu)
        XCTAssertNil(controller.menu.items.first?.view)
    }
}
