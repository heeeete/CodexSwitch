import AppKit
import XCTest
@testable import CodexSwitch

@MainActor
final class StatusMenuControllerTests: XCTestCase {
    // 실제 NSMenu 하위 항목이 현재 계정 표시와 작업 상태를 반영하고 상위 뷰를 보존한다.
    func testNativeAccountSubmenusTrackCurrentRegistryAndBusyState() async throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let suite = "NativeAccountMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoRefreshEnabled")
        let store = AccountStore(userDefaults: defaults, resetCreditLoader: { _ in [] })
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": 3, "active_account_key": "account-0",
            "accounts": (0..<10).map { ["account_key": "account-\($0)", "email": "account\($0)@example.com"] }
        ])
        let registry = try JSONDecoder().decode(AccountRegistry.self, from: data)
        store.applyPreviewRegistry(registry)
        let controller = StatusMenuController(store: store, updateStore: UpdateStore())
        defer {
            controller.stop()
            NSApp.mainMenu = previousMenu
            defaults.removePersistentDomain(forName: suite)
        }
        controller.menuWillOpen(controller.menu)
        let switching = try XCTUnwrap(controller.menu.items.first { $0.title == "계정 변경" }?.submenu)
        let removing = try XCTUnwrap(controller.menu.items.first { $0.title == "계정 제거" }?.submenu)
        XCTAssertEqual(switching.numberOfItems, 10)
        XCTAssertEqual(removing.numberOfItems, 10)
        XCTAssertTrue(switching.items.allSatisfy { $0.view == nil && $0.target === controller })
        XCTAssertEqual(switching.items[0].state, .on)
        XCTAssertFalse(switching.items[0].isEnabled)
        XCTAssertTrue(switching.items[1].isEnabled)
        XCTAssertTrue(removing.items[0].isEnabled)
        let firstOption = switching.items[0]
        controller.menuWillOpen(switching)
        controller.menuDidClose(switching)
        XCTAssertNotNil(controller.menu.items.first?.view)

        XCTAssertTrue(store.prepareForUpdateRestart())
        // 실제 관찰 경로로 상태가 바뀌는지 확인한다. 직접 갱신 메서드는 호출하지 않는다.
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(switching.items.allSatisfy { !$0.isEnabled })
        XCTAssertTrue(removing.items.allSatisfy { !$0.isEnabled })
        store.cancelUpdateRestart()
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(switching.items[1].isEnabled)
        XCTAssertTrue(firstOption === switching.items[0])

        // 활성 계정이 없는 단일 계정도 최초 전환 대상으로 사용할 수 있다.
        store.applyPreviewRegistry(AccountRegistry(schemaVersion: 3, activeAccountKey: nil, api: nil,
                                                  accounts: [registry.accounts[0]]))
        controller.menuWillOpen(switching)
        XCTAssertEqual(switching.numberOfItems, 1)
        XCTAssertEqual(switching.items[0].state, .off)
        XCTAssertTrue(switching.items[0].isEnabled)
        store.applyPreviewRegistry(.empty)
        controller.menuWillOpen(controller.menu)
        XCTAssertTrue(switching.items.isEmpty)
        XCTAssertFalse(controller.menu.items.first { $0.title == "계정 변경" }!.isEnabled)
        // 사라진 계정의 과거 항목을 호출해도 실제 계정 작업을 시작하지 않는다.
        NSApp.sendAction(try XCTUnwrap(firstOption.action), to: controller, from: firstOption)
        XCTAssertFalse(store.isBusy)
    }

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
