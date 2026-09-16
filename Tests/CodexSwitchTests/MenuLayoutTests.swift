import AppKit
import SwiftUI
import XCTest
@testable import CodexSwitch

@MainActor
final class MenuLayoutTests: LocalizedTestCase {
    // 선택한 큰 숫자 시안을 주간 전용·5시간 포함·잔여량 부족 상태로 실제 렌더링한다.
    func testRedesignedUsageAndCouponLayouts() async throws {
        let suite = "CodexSwitch-UsageLayout-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(false, forKey: "autoRefreshEnabled")
        defer { defaults.removePersistentDomain(forName: suite) }
        let now = Date()
        let credits = [504_060, 1_634_460, 1_728_060].enumerated().map { index, seconds in
            ResetCredit(id: String(index), status: "available", resetType: "codex_rate_limits",
                        expiresAt: now.addingTimeInterval(Double(seconds)))
        }
        for (name, dual, used, scheme) in [("weekly-dark", false, 15, ColorScheme.dark),
                                           ("weekly-light", false, 15, .light),
                                           ("dual-dark", true, 15, .dark),
                                           ("low-dark", false, 92, .dark)] {
            let weekly: [String: Any] = ["used_percent": used, "window_minutes": 10_080,
                                         "resets_at": Int(now.timeIntervalSince1970) + 504_060]
            let usage: [String: Any] = dual
                ? ["primary": ["used_percent": 25, "window_minutes": 300,
                                "resets_at": Int(now.timeIntervalSince1970) + 7_260], "secondary": weekly]
                : ["primary": weekly]
            let data = try JSONSerialization.data(withJSONObject: [
                "schema_version": 3, "active_account_key": "preview",
                "accounts": [["account_key": "preview", "email": "preview.account@example.com", "plan": "pro", "last_usage": usage],
                             ["account_key": "other", "email": "other@example.com"],
                             ["account_key": "third", "email": "third@example.com"]]
            ])
            let store = AccountStore(userDefaults: defaults, resetCreditLoader: { _ in credits })
            store.applyPreviewRegistry(try JSONDecoder().decode(AccountRegistry.self, from: data))
            for _ in 0..<100 where store.resetCreditState == .loading {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertEqual(store.resetCreditState, .loaded(credits))
            let hosting = NSHostingView(rootView: MenuContentView(store: store)
                .environment(\.colorScheme, scheme).environment(\.locale, Locale(identifier: "ko_KR")))
            let size = hosting.fittingSize
            XCTAssertEqual(size.width, 372, accuracy: 1)
            XCTAssertLessThan(size.height, 760)
            if let prefix = ProcessInfo.processInfo.environment["CODEXSWITCH_USAGE_SNAPSHOT_ROOT"] {
                hosting.frame = NSRect(origin: .zero, size: size)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(
                    to: URL(fileURLWithPath: "\(prefix)-\(name).png"))
            }
        }
    }

    // 시스템 Material이 밝은 모드와 어두운 모드에서 모두 같은 메뉴 구조를 유지한다.
    func testAccountMenuRendersInLightAndDarkAppearances() throws {
        let registry = try JSONDecoder().decode(
            AccountRegistry.self,
            from: Data(Self.accountRegistryJSON.utf8)
        )

        for colorScheme in [ColorScheme.light, .dark] {
            let service = CodexAuthService(
                registryURL: URL(fileURLWithPath: "/tmp/codex-switch-unused-registry"),
                environment: [:]
            )
            let store = AccountStore(authService: service)
            store.applyPreviewRegistry(registry)
            let hostingView = NSHostingView(
                rootView: MenuContentView(store: store)
                    .environment(\.colorScheme, colorScheme)
            )
            XCTAssertEqual(hostingView.fittingSize.width, 372, accuracy: 1)
            XCTAssertGreaterThan(hostingView.fittingSize.height, 280)
            // 두 사용량 창의 큰 숫자와 초기화 시간을 포함한 메뉴 높이를 제한한다.
            XCTAssertLessThan(hostingView.fittingSize.height, 720)
        }
    }

    // 빈 첫 실행 화면과 분리된 footer 행이 메뉴바 패널의 의도한 폭 안에 맞는지 렌더링한다.
    func testEmptyMenuLayoutRendersAtExpectedSize() throws {
        let registryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchMissing-\(UUID().uuidString)/accounts/registry.json")
        let service = CodexAuthService(registryURL: registryURL, environment: [:])
        let store = AccountStore(authService: service)
        let hostingView = NSHostingView(rootView: MenuContentView(store: store))

        let fittingSize = hostingView.fittingSize
        XCTAssertEqual(fittingSize.width, 372, accuracy: 1)
        XCTAssertGreaterThan(fittingSize.height, 280)
        // 자동 새로고침 행과 구분선에 필요한 35pt를 기존 높이 상한에 더한다.
        // 설정 명령 한 행이 추가된 빈 메뉴도 화면 안에서 여유 있게 열린다.
        XCTAssertLessThan(fittingSize.height, 620)

        // 요청된 경우 같은 렌더를 PNG로 저장해 사람 눈으로도 확인할 수 있게 한다.
        guard let snapshotPath = ProcessInfo.processInfo.environment["CODEXSWITCH_SNAPSHOT_PATH"],
              !snapshotPath.isEmpty else {
            return
        }

        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("메뉴 렌더 버퍼를 만들지 못했습니다.")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("메뉴 렌더를 PNG로 변환하지 못했습니다.")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
    }

    // 활성 표시, Pro 배율, 두 사용량 미터가 있는 계정 목록도 같은 폭에서 렌더링한다.
    func testAccountMenuLayoutRendersAtExpectedSize() throws {
        let service = CodexAuthService(
            registryURL: URL(fileURLWithPath: "/tmp/codex-switch-unused-registry"),
            environment: [:]
        )
        let store = AccountStore(authService: service)
        let registry = try JSONDecoder().decode(
            AccountRegistry.self,
            from: Data(Self.accountRegistryJSON.utf8)
        )
        store.applyPreviewRegistry(registry)

        let hostingView = NSHostingView(rootView: MenuContentView(store: store))
        let fittingSize = hostingView.fittingSize
        XCTAssertEqual(fittingSize.width, 372, accuracy: 1)
        XCTAssertGreaterThan(fittingSize.height, 280)
        // 두 사용량 창의 큰 숫자와 초기화 시간을 포함한 메뉴 높이를 제한한다.
        XCTAssertLessThan(fittingSize.height, 720)

        guard let snapshotPath = ProcessInfo.processInfo.environment["CODEXSWITCH_ACCOUNTS_SNAPSHOT_PATH"],
              !snapshotPath.isEmpty else {
            return
        }
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("계정 메뉴 렌더 버퍼를 만들지 못했습니다.")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("계정 메뉴 렌더를 PNG로 변환하지 못했습니다.")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
    }

    // 저장 계정 수가 늘어도 상단 현재 계정 카드 높이와 전체 폭은 하나일 때와 같다.
    func testCurrentAccountCardLayoutDoesNotGrowWithStoredAccountCount() throws {
        var renderedHeights: [CGFloat] = []

        for accountCount in [1, 3, 6] {
            let accountObjects: [[String: Any]] = (0..<accountCount).map { index in
                [
                    "account_key": "account-\(index)",
                    "email": "very.long.account.\(index)@example.com",
                    "alias": "very.long.account.\(index)@example.com",
                    "plan": index.isMultiple(of: 2) ? "pro" : "prolite",
                    "auth_mode": "chatgpt"
                ]
            }
            let registryData = try JSONSerialization.data(withJSONObject: [
                "schema_version": 3,
                "active_account_key": "account-0",
                "accounts": accountObjects
            ])
            let registry = try JSONDecoder().decode(AccountRegistry.self, from: registryData)
            let store = AccountStore(
                authService: CodexAuthService(
                    registryURL: URL(fileURLWithPath: "/tmp/codex-switch-unused-registry"),
                    environment: [:]
                )
            )
            store.applyPreviewRegistry(registry)

            let hostingView = NSHostingView(rootView: MenuContentView(store: store))
            XCTAssertEqual(hostingView.fittingSize.width, 372, accuracy: 1)
            XCTAssertGreaterThan(hostingView.fittingSize.height, 260)
            XCTAssertLessThan(hostingView.fittingSize.height, 650)
            renderedHeights.append(hostingView.fittingSize.height)
        }

        guard let firstHeight = renderedHeights.first else {
            XCTFail("현재 계정 카드 높이를 측정하지 못했습니다.")
            return
        }
        for height in renderedHeights.dropFirst() {
            XCTAssertEqual(height, firstHeight, accuracy: 1)
        }
    }

    // 활성 키가 없거나 오래돼도 첫 저장 계정을 현재 계정으로 잘못 표시하지 않는다.
    func testMissingActiveAccountRendersCompactSummary() throws {
        for activeAccountKey: Any in [NSNull(), "missing-account"] {
            let registryData = try JSONSerialization.data(withJSONObject: [
                "schema_version": 3,
                "active_account_key": activeAccountKey,
                "accounts": [[
                    "account_key": "available-account",
                    "email": "available@example.com",
                    "alias": "Available",
                    "plan": "pro",
                    "auth_mode": "chatgpt"
                ]]
            ])
            let registry = try JSONDecoder().decode(AccountRegistry.self, from: registryData)
            let store = AccountStore(
                authService: CodexAuthService(
                    registryURL: URL(fileURLWithPath: "/tmp/codex-switch-unused-registry"),
                    environment: [:]
                )
            )
            store.applyPreviewRegistry(registry)

            let hostingView = NSHostingView(rootView: MenuContentView(store: store))
            XCTAssertEqual(hostingView.fittingSize.width, 372, accuracy: 1)
            // 계정 명령은 별도 NSMenu 항목이므로 요약 뷰에는 헤더와 토글만 남는다.
            XCTAssertGreaterThan(hostingView.fittingSize.height, 100)
            XCTAssertLessThan(hostingView.fittingSize.height, 500)
        }
    }

    // 글자 수가 짧아도 실제 한 줄 폭을 넘으면 중앙에 펼치기 chevron을 렌더링한다.
    func testLongNoticeMenuLayoutRendersDisclosure() throws {
        let service = CodexAuthService(
            registryURL: URL(fileURLWithPath: "/tmp/codex-switch-unused-registry"),
            environment: [:]
        )
        let store = AccountStore(authService: service)
        let registry = try JSONDecoder().decode(
            AccountRegistry.self,
            from: Data(Self.accountRegistryJSON.utf8)
        )
        store.applyPreviewRegistry(registry)
        store.notice = AccountStore.Notice(
            style: .error,
            message: "ChatGPT가 종료되지 않았습니다. 직접 종료한 뒤 다시 열어 주세요."
        )

        let hostingView = NSHostingView(rootView: MenuContentView(store: store))
        let fittingSize = hostingView.fittingSize
        XCTAssertEqual(fittingSize.width, 372, accuracy: 1)
        XCTAssertGreaterThan(fittingSize.height, 340)
        // 첫 쿠폰 조회에도 세 줄을 확보하며, 화면보다 긴 내용은 NSMenu 호스트가 스크롤한다.
        XCTAssertLessThan(fittingSize.height, 760)

        guard let snapshotPath = ProcessInfo.processInfo.environment["CODEXSWITCH_NOTICE_SNAPSHOT_PATH"],
              !snapshotPath.isEmpty else {
            return
        }
        hostingView.frame = NSRect(origin: .zero, size: fittingSize)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(in: hostingView.bounds) else {
            XCTFail("긴 안내 메뉴 렌더 버퍼를 만들지 못했습니다.")
            return
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        guard let pngData = bitmap.representation(using: .png, properties: [:]) else {
            XCTFail("긴 안내 메뉴 렌더를 PNG로 변환하지 못했습니다.")
            return
        }
        try pngData.write(to: URL(fileURLWithPath: snapshotPath), options: .atomic)
    }

    // app-modal 확인창은 첫 번째 버튼만 확인으로 처리하고 파괴적 버튼 속성을 보존한다.
    func testSystemConfirmationAlertMapsFirstButtonToConfirmation() {
        let didConfirm = SystemConfirmationAlert.present(
            title: "계정 제거",
            message: "이 Mac의 인증 정보만 제거합니다.",
            confirmTitle: "제거",
            confirmIsDestructive: true
        ) { alert in
            XCTAssertEqual(alert.messageText, "계정 제거")
            XCTAssertEqual(alert.informativeText, "이 Mac의 인증 정보만 제거합니다.")
            XCTAssertEqual(alert.buttons.map(\.title), ["제거", "취소"])
            XCTAssertTrue(alert.buttons[0].hasDestructiveAction)
            return .alertFirstButtonReturn
        }

        XCTAssertTrue(didConfirm)
    }

    // 취소 버튼이나 시스템 취소 응답은 제거 확인으로 오인하지 않는다.
    func testSystemConfirmationAlertRejectsNonConfirmingResponse() {
        let didConfirm = SystemConfirmationAlert.present(
            title: "계정 제거",
            message: "이 Mac의 인증 정보만 제거합니다.",
            confirmTitle: "제거",
            confirmIsDestructive: true
        ) { _ in
            .alertSecondButtonReturn
        }

        XCTAssertFalse(didConfirm)
    }

    private static let accountRegistryJSON = #"""
    {
      "schema_version": 3,
      "active_account_key": "work-account",
      "api": { "usage": false, "account": false },
      "accounts": [
        {
          "account_key": "work-account",
          "email": "primary.account@example.com",
          "alias": "primary.account@example.com",
          "account_name": null,
          "plan": "pro",
          "auth_mode": "chatgpt",
          "last_used_at": 1700000000,
          "last_usage_at": 1700000001,
          "last_usage": {
            "plan_type": "pro",
            "primary": { "used_percent": 7, "window_minutes": 300, "resets_at": 1800000000 },
            "secondary": { "used_percent": 41, "window_minutes": 10080, "resets_at": 1800600000 }
          }
        },
        {
          "account_key": "personal-account",
          "email": "secondary.account@example.com",
          "alias": "secondary.account@example.com",
          "account_name": null,
          "plan": "prolite",
          "auth_mode": "chatgpt",
          "last_used_at": 1690000000,
          "last_usage_at": 1690000001,
          "last_usage": {
            "plan_type": "prolite",
            "primary": { "used_percent": 22, "window_minutes": 300, "resets_at": 1800000000 },
            "secondary": { "used_percent": 65, "window_minutes": 10080, "resets_at": 1800600000 }
          }
        }
      ]
    }
    """#
}
