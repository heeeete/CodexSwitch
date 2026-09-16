import AppKit
import SwiftUI
import XCTest
@testable import CodexSwitch

@MainActor
final class LocalizationTests: LocalizedTestCase {
    func testSystemLanguageAndSavedPreference() {
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ko-KR", "en-US"]), "ko")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["en-US", "ko-KR"]), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: ["ja-JP"]), "en")
        XCTAssertEqual(AppLanguage.system.resolved(preferredLanguages: []), "en")
        XCTAssertEqual(AppLanguage.korean.resolved(preferredLanguages: ["en-US"]), "ko")
        let suite = "LanguagePersistence-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "autoRefreshEnabled")
        let settings = LanguageSettings(defaults: defaults)
        XCTAssertEqual(settings.selection, .system)
        settings.selection = .english
        XCTAssertEqual(LanguageSettings(defaults: defaults).selection, .english)
        XCTAssertFalse(defaults.bool(forKey: "autoRefreshEnabled"))
        settings.selection = .system
        XCTAssertEqual(LanguageSettings(defaults: defaults).selection, .system)
    }

    // 빠진 번역과 치환 인수 불일치가 배포 전에 드러나야 한다.
    func testTranslationCatalogsHaveMatchingKeysAndArguments() throws {
        func catalog(_ language: String) throws -> [String: String] {
            let directory = try XCTUnwrap(L10n.resources.url(forResource: language, withExtension: "lproj"))
            return try XCTUnwrap(NSDictionary(contentsOf: directory.appendingPathComponent("Localizable.strings")) as? [String: String])
        }
        let korean = try catalog("ko")
        let english = try catalog("en")
        XCTAssertGreaterThan(english.count, 100)
        XCTAssertEqual(Set(korean.keys), Set(english.keys))
        let placeholder = try NSRegularExpression(pattern: #"%(?:\d+\$)?@"#)
        for (key, translation) in english {
            let original = try XCTUnwrap(korean[key])
            XCTAssertFalse(translation.isEmpty, key)
            XCTAssertNil(translation.range(of: "[가-힣]", options: .regularExpression), key)
            XCTAssertEqual(placeholder.numberOfMatches(in: original, range: NSRange(original.startIndex..., in: original)),
                           placeholder.numberOfMatches(in: translation, range: NSRange(translation.startIndex..., in: translation)), key)
        }
    }

    // 계정과 업데이트 상태는 그대로 두고 이미 열린 화면과 안내 문구만 즉시 바꾼다.
    func testLanguageChangesUpdateNativeMenusAndExistingMessages() async throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let language = LanguageSettings.shared
        let previousLanguage = language.selection
        language.selection = .korean
        let suite = "LanguageLiveMenu-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoRefreshEnabled")
        let store = AccountStore(userDefaults: defaults, resetCreditLoader: { _ in [] })
        store.applyPreviewRegistry(try registry())
        store.notice = AccountStore.Notice(style: .warning, message: L10n.text("새로 고침을 취소했습니다."))
        let noticeID = store.notice?.id
        let updates = UpdateStore()
        let driver = UpdateUserDriver(store: updates)
        driver.showReady { _ in }
        let controller = StatusMenuController(store: store, updateStore: updates)
        defer {
            controller.stop()
            NSApp.mainMenu = previousMenu
            language.selection = previousLanguage
            defaults.removePersistentDomain(forName: suite)
        }
        controller.openSettings()
        XCTAssertEqual(controller.statusItem.button?.title, " 주간 81%")
        language.selection = .english
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.statusItem.button?.title, " Weekly 81%")
        XCTAssertEqual(controller.settingsWindow?.title, "CodexSwitch Settings")
        let switching = try XCTUnwrap(controller.menu.items.first { $0.title == "Switch Account" }?.submenu)
        XCTAssertTrue(switching.items[0].title.contains("Weekly 81% left"))
        XCTAssertTrue(controller.menu.items.contains { $0.title == "Remove Account" })
        XCTAssertTrue(controller.menu.items.contains { $0.title == "Settings…" })
        XCTAssertEqual(store.notice?.message, "Refresh cancelled.")
        XCTAssertEqual(store.notice?.id, noticeID)
        XCTAssertEqual(updates.status, .ready)
        XCTAssertEqual(updates.message, "An update is ready. Restart now?")
        XCTAssertEqual(store.activeAccountKey, "work")
        XCTAssertEqual(store.accounts.map(\.id), ["work"])
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.autoRefreshEnabled)

        language.selection = .korean
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertEqual(controller.settingsWindow?.title, "CodexSwitch 설정")
        XCTAssertEqual(controller.statusItem.button?.title, " 주간 81%")
        XCTAssertEqual(store.notice?.message, "새로 고침을 취소했습니다.")
    }

    // 긴 영어 문구도 설정 폼과 기존 메뉴 너비 안에 렌더링되는지 확인한다.
    func testBothLanguageLayoutsAndUpdateMessages() throws {
        let language = LanguageSettings.shared
        let previous = language.selection
        defer { language.selection = previous }
        let suite = "LanguageLayout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoRefreshEnabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AccountStore(userDefaults: defaults, resetCreditLoader: { _ in [] })
        store.applyPreviewRegistry(try registry())
        let updates = UpdateStore()
        UpdateUserDriver(store: updates).showUserInitiatedUpdateCheck(cancellation: {})
        for choice in [AppLanguage.korean, .english] {
            language.selection = choice
            XCTAssertEqual(updates.checkMessage, choice == .english ? "Checking for updates…" : "업데이트를 확인하고 있어요.")
            let settings = NSHostingView(rootView: SettingsView(updateStore: updates, accountStore: store))
            let menu = NSHostingView(rootView: MenuContentView(store: store, updateStore: updates))
            XCTAssertEqual(settings.fittingSize.width, 460, accuracy: 1)
            XCTAssertLessThan(settings.fittingSize.height, 700)
            XCTAssertEqual(menu.fittingSize.width, 372, accuracy: 1)
            XCTAssertLessThan(menu.fittingSize.height, 700)
            if let prefix = ProcessInfo.processInfo.environment["CODEXSWITCH_LANGUAGE_SNAPSHOT_ROOT"] {
                for (name, view) in [("settings", settings as NSView), ("menu", menu as NSView)] {
                    view.frame = NSRect(origin: .zero, size: view.fittingSize)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                        to: URL(fileURLWithPath: "\(prefix)-\(name)-\(choice.rawValue).png"))
                }
            }
        }
    }

    private func registry() throws -> AccountRegistry {
        let now = Int64(Date().timeIntervalSince1970)
        let data = try JSONSerialization.data(withJSONObject: [
            "schema_version": 3, "active_account_key": "work",
            "accounts": [["account_key": "work", "email": "work@example.com", "last_usage_at": now,
                          "last_usage": ["primary": ["used_percent": 19, "window_minutes": 10_080, "resets_at": now + 100_000]]]]
        ])
        return try JSONDecoder().decode(AccountRegistry.self, from: data)
    }
}
