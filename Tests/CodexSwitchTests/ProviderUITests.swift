import AppKit
import SwiftUI
import XCTest
@testable import CodexSwitch

@MainActor
final class ProviderUITests: LocalizedTestCase {
    // 같은 계정 키가 두 서비스에 있어도 탭을 바꾸면 메뉴 대상을 새로 만든다.
    func testNativeMenusFollowSelectedProviderAndRejectOldItems() async throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let suite = "ProviderMenus-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            NSApp.mainMenu = previousMenu
            defaults.removePersistentDomain(forName: suite)
        }
        let accounts = try makeAccounts(defaults: defaults)
        let controller = StatusMenuController(accounts: accounts, updateStore: UpdateStore())
        defer { controller.stop() }
        controller.menuWillOpen(controller.menu)
        let hostedView = try XCTUnwrap(controller.menu.items.first?.view)
        let switching = try XCTUnwrap(controller.menu.items.first { $0.title == "계정 변경" }?.submenu)
        let codexItem = switching.items[1]
        XCTAssertTrue(codexItem.title.contains("codex-second@example.com"))
        XCTAssertEqual(controller.statusItem.button?.title, " 5h 90% · 주간 81%")
        XCTAssertTrue(controller.statusItem.button?.image === CodexSwitchIcon.menuBarImage(for: .codex))

        accounts.select(.claude)
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(hostedView === controller.menu.items.first?.view)
        XCTAssertEqual(switching.numberOfItems, 2)
        XCTAssertTrue(switching.items[1].title.contains("claude-second@example.com"))
        XCTAssertEqual(switching.items[1].identifier?.rawValue, "claude")
        XCTAssertFalse(codexItem === switching.items[1])
        XCTAssertEqual(controller.statusItem.button?.title, " 5h 90% · 주간 62%")
        // 메뉴바 숫자 옆 아이콘도 선택한 탭의 서비스로 바뀐다.
        XCTAssertTrue(controller.statusItem.button?.image === CodexSwitchIcon.menuBarImage(for: .claude))
        XCTAssertEqual(accounts.codex.activeAccountKey, "shared-current")
        XCTAssertEqual(accounts.claude.activeAccountKey, "shared-current")

        // 이미 제거된 메뉴 항목이 늦게 전달돼도 다른 서비스의 같은 키를 실행하지 않는다.
        NSApp.sendAction(try XCTUnwrap(codexItem.action), to: controller, from: codexItem)
        XCTAssertFalse(accounts.isBusy)
        XCTAssertNil(accounts.claude.switchingAccountKey)

        XCTAssertTrue(accounts.codex.prepareForUpdateRestart())
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertTrue(switching.items.allSatisfy { !$0.isEnabled })
        accounts.codex.cancelUpdateRestart()
    }

    // 한 메뉴 안에서 탭을 바꿔도 뷰포트가 유지되고 두 언어의 긴 문구가 같은 폭에 들어간다.
    func testProviderLayoutsAndStableViewport() throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let language = LanguageSettings.shared
        let previousLanguage = language.selection
        let suite = "ProviderLayout-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            NSApp.mainMenu = previousMenu
            language.selection = previousLanguage
            defaults.removePersistentDomain(forName: suite)
        }
        let accounts = try makeAccounts(defaults: defaults)
        let updates = UpdateStore()
        let controller = StatusMenuController(accounts: accounts, updateStore: updates)
        defer { controller.stop() }
        controller.menuWillOpen(controller.menu)
        let viewport = try XCTUnwrap(controller.menu.items.first?.view)
        XCTAssertEqual(viewport.frame.width, 372, accuracy: 1)
        XCTAssertLessThanOrEqual(viewport.frame.height, 620)

        for choice in [AppLanguage.korean, .english] {
            language.selection = choice
            var heights: [CGFloat] = []
            for provider in AccountProvider.allCases {
                accounts.select(provider)
                // 네이티브 컨트롤과 글자를 같은 다크 외관의 불투명 배경에서 검증한다.
                let hosting = NSHostingView(rootView:
                    ProviderMenuContentView(accounts: accounts, updateStore: updates)
                        .environment(\.colorScheme, .dark)
                        .background(Color(nsColor: .windowBackgroundColor))
                )
                hosting.appearance = NSAppearance(named: .darkAqua)
                let size = hosting.fittingSize
                heights.append(size.height)
                XCTAssertEqual(size.width, 372, accuracy: 1)
                XCTAssertGreaterThan(size.height, 250)
                XCTAssertLessThan(size.height, 720)
                XCTAssertEqual(viewport.frame.height, controller.menu.items.first?.view?.frame.height)
                guard let prefix = ProcessInfo.processInfo.environment["CODEXSWITCH_PROVIDER_SNAPSHOT_ROOT"] else { continue }
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: "\(prefix)-\(provider.rawValue)-\(choice.rawValue).png"))
            }
            // Claude에는 Codex 쿠폰 영역을 표시하지 않는다.
            XCTAssertGreaterThan(heights[0], heights[1] + 35)
        }
    }

    // 열린 메뉴는 안내가 뜨면 그만큼 길어지고 닫으면 줄어들며, 탭을 바꿔도 내용 높이를 따른다.
    func testOpenMenuHeightFollowsContent() async throws {
        _ = NSApplication.shared
        let previousMenu = NSApp.mainMenu
        let suite = "ProviderMenuHeight-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            NSApp.mainMenu = previousMenu
            defaults.removePersistentDomain(forName: suite)
        }
        let accounts = try makeAccounts(defaults: defaults)
        let updates = UpdateStore()
        let controller = StatusMenuController(accounts: accounts, updateStore: updates)
        defer { controller.stop() }
        controller.menuWillOpen(controller.menu)
        let view = try XCTUnwrap(controller.menu.items.first?.view)
        // 실제 메뉴처럼 창 안에서 배치되도록 화면 밖 창에 올려 SwiftUI 갱신을 받게 한다.
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 372, height: 900),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView?.addSubview(view)
        window.orderFrontRegardless()
        defer { window.close() }
        // 쿠폰 조회와 안내문 측정이 끝나 높이가 더 변하지 않을 때의 값을 읽는다.
        func settledHeight() async throws -> CGFloat {
            var last = view.frame.height
            var unchanged = 0
            for _ in 0..<150 where unchanged < 10 {
                try await Task.sleep(for: .milliseconds(20))
                unchanged = abs(view.frame.height - last) < 0.5 ? unchanged + 1 : 0
                last = view.frame.height
            }
            return last
        }
        func natural(_ store: AccountStore) -> CGFloat {
            NSHostingView(rootView: MenuContentView(store: store, updateStore: updates)).fittingSize.height
        }
        // CI처럼 낮은 화면에서는 메뉴가 화면 한도에서 멈추므로, 그 한도까지 내용 높이를 따르는지 확인한다.
        let limit = controller.availableContentHeight
        func expected(_ store: AccountStore) -> CGFloat { min(natural(store), limit) }
        let base = try await settledHeight()
        XCTAssertEqual(base, expected(accounts.codex), accuracy: 1)

        accounts.codex.notice = AccountStore.Notice(
            style: .error, message: "Claude 서버에 연결하지 못했습니다. 네트워크를 확인한 뒤 새로고침해 주세요.")
        let withNotice = try await settledHeight()
        // 안내만큼 길어지고, 그만큼 늘릴 공간이 없는 낮은 화면에서는 한도에서 멈춘다.
        if base + 20 < limit {
            XCTAssertGreaterThan(withNotice, base + 20)
        } else {
            XCTAssertEqual(withNotice, limit, accuracy: 1)
        }
        accounts.codex.dismissNotice()
        let dismissed = try await settledHeight()
        XCTAssertEqual(dismissed, base, accuracy: 1)

        // Claude 탭은 쿠폰 영역이 없어 더 짧고, 빈 공간 없이 그 높이로 줄어든다.
        accounts.select(.claude)
        let claude = try await settledHeight()
        XCTAssertEqual(claude, expected(accounts.claude), accuracy: 1)
        if natural(accounts.codex) < limit { XCTAssertLessThan(claude, base - 35) }
    }

    // Claude 사용량이 비어 있는 이유와 빠진 기간 안내가 두 언어에서 메뉴 폭 안에 표시된다.
    func testClaudeUsageNotesFitMenuInBothLanguages() throws {
        _ = NSApplication.shared
        let language = LanguageSettings.shared
        let previousLanguage = language.selection
        let suite = "ClaudeUsageNotes-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(false, forKey: "claudeAutoRefreshEnabled")
        defer {
            language.selection = previousLanguage
            defaults.removePersistentDomain(forName: suite)
        }
        let updates = UpdateStore()
        func render(_ name: String, authMode: String = "claude", usage: UsageSnapshot? = nil,
                    issues: [any Error] = []) throws -> CGFloat {
            let service = CodexAuthService(
                registryURL: URL(fileURLWithPath: "/tmp/claude-notes-unused-\(UUID().uuidString)/registry.json"),
                environment: [:])
            let store = AccountStore(authService: service, provider: .claude, userDefaults: defaults,
                                     resetCreditLoader: { _ in [] })
            let account = CodexAccount(accountKey: "current", email: "claude@example.com", alias: nil, accountName: nil,
                                       plan: "max", authMode: authMode, lastUsedAt: nil, lastUsageAt: 1_800_000_000,
                                       lastUsage: usage, usageIssues: issues)
            store.applyPreviewRegistry(AccountRegistry(schemaVersion: 3, activeAccountKey: "current", api: nil, accounts: [account]))
            let hosting = NSHostingView(rootView:
                MenuContentView(store: store, updateStore: updates)
                    .environment(\.colorScheme, .dark)
                    .background(Color(nsColor: .windowBackgroundColor))
            )
            hosting.appearance = NSAppearance(named: .darkAqua)
            let size = hosting.fittingSize
            XCTAssertEqual(size.width, 372, accuracy: 1, name)
            XCTAssertLessThan(size.height, 720, name)
            if let prefix = ProcessInfo.processInfo.environment["CODEXSWITCH_PROVIDER_SNAPSHOT_ROOT"] {
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: "\(prefix)-claude-\(name)-\(language.selection.rawValue).png"))
            }
            return size.height
        }
        let weeklyOnly = UsageSnapshot(primary: nil,
                                       secondary: UsageWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: nil),
                                       planType: nil)
        for choice in [AppLanguage.korean, .english] {
            language.selection = choice
            let plain = try render("plain")
            // 원인이 있으면 일반 문구 대신 기록 없음과 조회 실패 이유를 모두 보여 준다.
            let explained = try render("explained", issues: [ClaudeUsageError.ambiguousOrganization,
                                                             ClaudeUsageError.accessDenied(.usage)])
            XCTAssertGreaterThan(explained, plain + 20)
            // 구독하지 않은 계정은 다른 안내 없이 그 사실 한 가지만 보여 준다.
            let unsubscribed = try render("unsubscribed", issues: [ClaudeUsageError.notSubscribed])
            XCTAssertLessThan(unsubscribed, explained - 20)
            // 한 기간만 있으면 그 값을 보여 주고 빠진 기간은 한 줄로 따로 알린다.
            let partial = try render("partial", usage: weeklyOnly)
            let codexStyle = try render("partial-codex", authMode: "chatgpt", usage: weeklyOnly)
            XCTAssertGreaterThan(partial, codexStyle + 8)
            // 사용 중인 기간의 초기화 시각을 모르면 새로고침 안내를 한 줄 더 보여 준다.
            let withReset = try render("partial-reset", usage: UsageSnapshot(
                primary: nil, secondary: UsageWindow(usedPercent: 40, windowMinutes: 10_080, resetsAt: 1_900_000_000),
                planType: nil))
            XCTAssertGreaterThan(partial, withReset + 8)
            // 모델별 주간 한도가 있으면 두 기간 아래에 한 칸 더 보여 주고 메뉴 높이 안에 들어간다.
            var both = UsageSnapshot(primary: UsageWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil),
                                     secondary: UsageWindow(usedPercent: 6, windowMinutes: 10_080, resetsAt: 1_900_000_000),
                                     planType: nil)
            let twoMeters = try render("two-meters", usage: both)
            both.scoped = [UsageWindow(usedPercent: 11, windowMinutes: 10_080, resetsAt: 1_900_000_000, scope: "Fable")]
            XCTAssertGreaterThan(try render("model-weekly", usage: both), twoMeters + 60)
        }
    }

    private func makeAccounts(defaults: UserDefaults) throws -> ProviderAccounts {
        defaults.set(false, forKey: "autoRefreshEnabled")
        defaults.set(false, forKey: "claudeAutoRefreshEnabled")
        let stores = try AccountProvider.allCases.map { provider in
            let service = CodexAuthService(
                registryURL: URL(fileURLWithPath: "/tmp/provider-ui-unused-\(UUID().uuidString)/registry.json"),
                environment: [:])
            let store = AccountStore(authService: service, provider: provider, userDefaults: defaults,
                                     resetCreditLoader: { _ in [] })
            let usage: [String: Any] = [
                "primary": ["used_percent": 10, "window_minutes": 300, "resets_at": 1_900_000_000],
                "secondary": ["used_percent": provider == .codex ? 19 : 38,
                              "window_minutes": 10_080, "resets_at": 1_900_100_000]
            ]
            let data = try JSONSerialization.data(withJSONObject: [
                "schema_version": 3, "active_account_key": "shared-current",
                "accounts": [
                    ["account_key": "shared-current", "email": "\(provider.rawValue)@example.com",
                     "plan": "pro", "auth_mode": provider == .claude ? "claude" : "chatgpt", "last_usage": usage],
                    ["account_key": "shared-second", "email": "\(provider.rawValue)-second@example.com"]
                ]
            ])
            store.applyPreviewRegistry(try JSONDecoder().decode(AccountRegistry.self, from: data))
            return store
        }
        return ProviderAccounts(codex: stores[0], claude: stores[1], userDefaults: defaults, initialProvider: .codex)
    }
}
