import Foundation
import XCTest
@testable import CodexSwitch

@MainActor
final class AutoRefreshTests: XCTestCase {
    // 기본값은 꺼짐이며 켜고 끈 선택 모두 새 Store에 복원된다.
    func testPreferenceDefaultsOffAndPersists() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        XCTAssertFalse(store.autoRefreshEnabled)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(fixture.invocations.count, 0)

        store.autoRefreshEnabled = true
        let restored = fixture.makeStore()
        XCTAssertTrue(restored.autoRefreshEnabled)
        restored.autoRefreshEnabled = false
        store.autoRefreshEnabled = false
        XCTAssertFalse(fixture.makeStore().autoRefreshEnabled)
    }

    // 메뉴 View 없이 시작해도 계정을 읽고 반복 조회 결과가 화면 상태에 반영된다.
    func testSavedPreferenceRefreshesUsageWithoutOpeningMenu() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "autoRefreshEnabled")
        let store = fixture.makeStore()
        defer { store.autoRefreshEnabled = false }
        try await waitUntil { fixture.invocations.count == 1 && !store.isBusy }
        XCTAssertEqual(store.activeAccount?.account.lastUsage?.primary?.usedPercent, 10)

        try fixture.writeRegistry(usedPercent: 42, to: fixture.nextRegistryURL)
        try await waitUntil { fixture.invocations.count >= 2 && !store.isBusy }
        XCTAssertEqual(store.activeAccount?.account.lastUsage?.primary?.usedPercent, 42)
        try await waitUntil { fixture.invocations.count >= 3 && !store.isBusy }
        XCTAssertTrue(fixture.invocations.allSatisfy { $0 == "list --skip-api" })
        XCTAssertNil(store.notice)
    }

    // 자동 조회도 기존 API 선택을 따르고 설정을 바꾸면 다음 주기부터 로컬 조회를 사용한다.
    func testAutomaticRefreshUsesCurrentAPISetting() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(true, forKey: "directAPIRefreshEnabled")
        let store = fixture.makeStore()
        defer { store.autoRefreshEnabled = false }
        await store.loadLocalAccounts()
        store.autoRefreshEnabled = true
        try await waitUntil { fixture.invocations.contains("list --api") && !store.isBusy }
        store.setDirectAPIRefreshEnabled(false)
        let previousCount = fixture.invocations.count
        try await waitUntil { fixture.invocations.count > previousCount && !store.isBusy }
        XCTAssertEqual(fixture.invocations.last, "list --skip-api")
    }

    // 끄면 이후 주기가 멈추며 빠르게 다시 켜도 예약이 중복되지 않는다.
    func testDisablingStopsRefreshAndReenablingRestartsIt() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        defer { store.autoRefreshEnabled = false }
        await store.loadLocalAccounts()
        store.autoRefreshEnabled = true
        try await waitUntil { fixture.invocations.count >= 2 && !store.isBusy }
        store.autoRefreshEnabled = false
        let stoppedCount = fixture.invocations.count
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(fixture.invocations.count, stoppedCount)

        for _ in 0..<5 {
            store.autoRefreshEnabled = true
            store.autoRefreshEnabled = false
        }
        store.autoRefreshEnabled = true
        try await waitUntil { fixture.invocations.count > stoppedCount && !store.isBusy }
        store.autoRefreshEnabled = false
        XCTAssertEqual(fixture.invocations.count, stoppedCount + 1)
    }

    // 수동 조회가 여러 주기 동안 진행되어도 자동 조회를 중복 실행하거나 대기열에 쌓지 않는다.
    func testAutomaticRefreshSkipsBusyStore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        let store = fixture.makeStore()
        defer { store.autoRefreshEnabled = false }
        await store.loadLocalAccounts()
        try Data().write(to: fixture.blockURL)
        store.refresh()
        try await waitUntil { fixture.invocations.count == 2 }
        store.autoRefreshEnabled = true
        try await Task.sleep(for: .milliseconds(450))
        XCTAssertTrue(store.isRefreshing)
        XCTAssertEqual(fixture.invocations.count, 2)
        store.autoRefreshEnabled = false
        try FileManager.default.removeItem(at: fixture.blockURL)
        try await waitUntil { !store.isBusy }
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(fixture.invocations.count, 2)
    }

    // 저장 계정이 없으면 반복 helper 실행 없이 설정만 유지한다.
    func testAutomaticRefreshSkipsEmptyAccounts() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(at: fixture.registryURL)
        let store = fixture.makeStore()
        defer { store.autoRefreshEnabled = false }
        store.autoRefreshEnabled = true
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(fixture.invocations.count, 0)
        XCTAssertNil(store.notice)
    }

    // 반복 대기 작업이 Store를 계속 잡아두지 않아 해제 후에도 조회가 남지 않는다.
    func testAutomaticRefreshDoesNotRetainStore() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanUp() }
        var store: AccountStore? = fixture.makeStore()
        weak var releasedStore: AccountStore?
        releasedStore = store
        await store?.loadLocalAccounts()
        store?.autoRefreshEnabled = true
        try await waitUntil { fixture.invocations.count >= 2 && store?.isBusy == false }
        store = nil
        XCTAssertNil(releasedStore)
        let stoppedCount = fixture.invocations.count
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(fixture.invocations.count, stoppedCount)
    }

    // 프로세스 실행은 유한한 시간 안에서 관찰해 느린 CI에서도 고정 sleep에 의존하지 않는다.
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), "자동 새로고침 상태가 제한 시간 안에 반영되어야 합니다.")
    }

    // 실제 인증정보 대신 임시 registry·helper·설정 저장소로 주기 동작을 검증한다.
    @MainActor
    private final class Fixture {
        let rootURL: URL
        let defaults: UserDefaults
        let suiteName = "CodexSwitchAutoRefresh-\(UUID().uuidString)"
        var registryURL: URL { rootURL.appendingPathComponent("accounts/registry.json") }
        var nextRegistryURL: URL { rootURL.appendingPathComponent("next.json") }
        var blockURL: URL { rootURL.appendingPathComponent("block") }
        var helperURL: URL { rootURL.appendingPathComponent("codex-auth") }
        var countURL: URL { rootURL.appendingPathComponent("calls") }
        var invocations: [String] {
            ((try? String(contentsOf: countURL, encoding: .utf8)) ?? "")
                .split(whereSeparator: \.isNewline).map(String.init)
        }

        init() throws {
            rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
            defaults = UserDefaults(suiteName: suiteName)!
            try FileManager.default.createDirectory(
                at: registryURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try writeRegistry(usedPercent: 10, to: registryURL)
            let script = """
            #!/bin/sh
            /bin/echo "$*" >> "$CODEXSWITCH_COUNT_FILE"
            while test -f "$CODEXSWITCH_BLOCK_FILE"; do
                /bin/sleep 0.02
            done
            if test -f "$CODEXSWITCH_NEXT_REGISTRY"; then
                /bin/cp "$CODEXSWITCH_NEXT_REGISTRY" "$CODEX_HOME/accounts/registry.json"
            fi
            """
            try Data(script.utf8).write(to: helperURL)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: helperURL.path
            )
        }

        func makeStore() -> AccountStore {
            AccountStore(
                authService: CodexAuthService(
                    registryURL: registryURL,
                    environment: [
                        "HOME": rootURL.path,
                        "CODEX_HOME": rootURL.path,
                        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                        "CODEX_AUTH_NODE_EXECUTABLE": "/usr/bin/true",
                        "CODEX_SWITCH_HELPER_EXECUTABLE": helperURL.path,
                        "CODEXSWITCH_COUNT_FILE": countURL.path,
                        "CODEXSWITCH_BLOCK_FILE": blockURL.path,
                        "CODEXSWITCH_NEXT_REGISTRY": nextRegistryURL.path
                    ]
                ),
                userDefaults: defaults,
                autoRefreshInterval: .milliseconds(150)
            )
        }

        func writeRegistry(usedPercent: Int, to url: URL) throws {
            let json = """
            {"schema_version":3,"active_account_key":"test","accounts":[
              {"account_key":"test","email":"test@example.com","last_usage":{
                "primary":{"used_percent":\(usedPercent),"window_minutes":300}
              }}
            ]}
            """
            try Data(json.utf8).write(to: url, options: .atomic)
        }

        func cleanUp() {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: rootURL)
        }
    }
}
