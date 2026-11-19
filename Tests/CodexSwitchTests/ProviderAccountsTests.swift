import Foundation
import XCTest
@testable import CodexSwitch

@MainActor
final class ProviderAccountsTests: LocalizedTestCase {
    // 탭 선택은 표시 대상만 바꾸고 두 서비스의 실제 계정 작업을 실행하지 않는다.
    func testSelectionPersistsWithoutSwitchingCredentials() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let codexService = TestAccountService(email: "codex@example.com")
        let claudeService = TestAccountService(email: "claude@example.com")
        let codex = fixture.store(service: codexService)
        let claude = fixture.store(service: claudeService, provider: .claude)
        await codex.loadLocalAccounts()
        await claude.loadLocalAccounts()
        // Claude는 첫 로드 뒤에 실시간 조회가 이어지므로 끝난 다음 탭을 바꾼다.
        try await waitUntil { !claude.isBusy }
        let accounts = ProviderAccounts(codex: codex, claude: claude, userDefaults: fixture.defaults)
        accounts.select(.claude)
        XCTAssertTrue(accounts.selectedStore === claude)
        XCTAssertEqual(accounts.selectedStore.activeAccount?.account.email, "claude@example.com")
        XCTAssertEqual(codex.activeAccountKey, "same-key")
        XCTAssertEqual(claude.activeAccountKey, "same-key")
        let restored = ProviderAccounts(codex: codex, claude: claude, userDefaults: fixture.defaults)
        XCTAssertEqual(restored.selectedProvider, .claude)
        let codexMutations = await codexService.mutationCount
        let claudeMutations = await claudeService.mutationCount
        XCTAssertEqual(codexMutations, 0)
        XCTAssertEqual(claudeMutations, 0)
    }

    // 기존 Codex 설정 키를 유지하며 Claude의 선택은 별도 키로 저장한다.
    func testPreferencesAreIndependent() {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let service = TestAccountService(email: "test@example.com")
        let codex = fixture.store(service: service)
        let claude = fixture.store(service: service, provider: .claude)
        codex.restartChatGPTAfterSwitch = false
        claude.restartChatGPTAfterSwitch = true
        codex.autoRefreshEnabled = false
        claude.autoRefreshEnabled = true
        let restoredCodex = fixture.store(service: service)
        let restoredClaude = fixture.store(service: service, provider: .claude)
        defer { claude.autoRefreshEnabled = false; restoredClaude.autoRefreshEnabled = false }
        XCTAssertFalse(restoredCodex.restartChatGPTAfterSwitch)
        XCTAssertTrue(restoredClaude.restartChatGPTAfterSwitch)
        XCTAssertFalse(restoredCodex.autoRefreshEnabled)
        XCTAssertTrue(restoredClaude.autoRefreshEnabled)
    }

    // 계정이 바뀐 뒤에는 승인창 없이 한 번만 조회하고, 전환 결과 안내를 지우거나 조회 오류로 덮지 않는다.
    func testAccountChangeRefreshesOnceAndKeepsResultNotice() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "claudeAutoRefreshEnabled")
        let service = TestAccountService(email: "claude@example.com")
        let store = AccountStore(authService: service, provider: .claude, userDefaults: fixture.defaults,
                                 switchRefreshDelay: .milliseconds(40))
        await store.loadLocalAccounts()
        try await waitUntil { !store.isBusy }
        store.notice = AccountStore.Notice(style: .success, message: "전환했습니다.")
        let noticeID = try XCTUnwrap(store.notice?.id)

        // 다시 열린 앱이 기록을 남길 시간을 둔 뒤에 조회를 시작한다. 첫 항목은 첫 로드 뒤의 조회다.
        store.refreshAfterAccountChange()
        try await Task.sleep(for: .milliseconds(10))
        var policies = await service.refreshPolicies
        XCTAssertEqual(policies, [false])
        try await waitUntil { store.isRefreshing }
        try await waitUntil { !store.isBusy }
        policies = await service.refreshPolicies
        XCTAssertEqual(policies, [false, false])
        XCTAssertEqual(store.notice?.id, noticeID)

        // 조회가 실패해도 전환 성공 안내는 남기고, 디스크에 기록된 결과는 화면에 반영한다.
        await service.failRefreshAfterSavingPartialResult()
        store.refreshAfterAccountChange()
        try await waitUntil { store.isRefreshing }
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.notice?.id, noticeID)
        XCTAssertEqual(store.notice?.style, .success)
        XCTAssertEqual(store.activeAccount?.account.lastUsageAt, 2_000)

        // 기다리는 동안 다른 작업이 시작되면 겹쳐 조회하지 않는다.
        store.refreshAfterAccountChange()
        XCTAssertTrue(store.prepareForUpdateRestart())
        try await Task.sleep(for: .milliseconds(120))
        policies = await service.refreshPolicies
        XCTAssertEqual(policies.count, 3)
        store.cancelUpdateRestart()
    }

    // 첫 화면은 서버를 기다리지 않고 바로 뜨며, 이어지는 조회는 승인창 없이 한 번만 돌고 실패해도 오류를 띄우지 않는다.
    func testFirstLoadShowsAccountsBeforeLiveLookup() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        fixture.defaults.set(false, forKey: "claudeAutoRefreshEnabled")
        let service = TestAccountService(email: "claude@example.com")
        await service.failRefreshAfterSavingPartialResult()
        let store = fixture.store(service: service, provider: .claude)
        await store.loadLocalAccounts()
        XCTAssertFalse(store.isLoading)
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertTrue(store.isRefreshing)
        try await waitUntil { !store.isBusy }
        await store.loadLocalAccounts()
        try await Task.sleep(for: .milliseconds(60))
        let policies = await service.refreshPolicies
        XCTAssertEqual(policies, [false])
        XCTAssertNil(store.notice)
        // 실패한 조회도 서비스가 저장한 결과는 화면에 반영한다.
        XCTAssertEqual(store.activeAccount?.account.lastUsageAt, 2_000)
    }

    // 수동 조회만 키체인 승인창을 허용하며 자동 조회에는 그 권한을 넘기지 않는다.
    func testRefreshPassesInteractivePolicyAndSkipsClaudeCoupons() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let service = TestAccountService(email: "claude@example.com")
        let store = fixture.store(service: service, provider: .claude)
        await store.loadLocalAccounts()
        // 첫 로드 뒤에 이어지는 조회도 승인창을 띄우지 않는다.
        try await waitUntil { !store.isBusy }
        store.refresh(interactive: false)
        try await waitUntil { !store.isBusy }
        store.refresh()
        try await waitUntil { !store.isBusy }
        let policies = await service.refreshPolicies
        let creditCalls = await service.creditCalls
        XCTAssertEqual(policies, [false, false, true])
        XCTAssertEqual(creditCalls, 0)
    }

    // 숨겨진 탭에서 진행 중인 조회도 앱 업데이트보다 먼저 끝나야 하지만, 조회 중이라고 탭 전환을 막지는 않는다.
    func testBusyAndUpdateRestartCoverBothServices() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let service = TestAccountService(email: "test@example.com")
        let codex = fixture.store(service: service)
        let claude = fixture.store(service: service, provider: .claude)
        let accounts = ProviderAccounts(codex: codex, claude: claude, userDefaults: fixture.defaults)
        claude.refresh()
        XCTAssertTrue(accounts.isBusy)
        XCTAssertFalse(accounts.isAccountOperationBusy)
        accounts.select(.claude)
        XCTAssertEqual(accounts.selectedProvider, .claude)
        XCTAssertFalse(accounts.prepareForUpdateRestart())
        try await waitUntil { !accounts.isBusy }
        XCTAssertTrue(accounts.prepareForUpdateRestart())
        XCTAssertTrue(codex.isRestartingForUpdate)
        XCTAssertTrue(claude.isRestartingForUpdate)
        accounts.cancelUpdateRestart()
        XCTAssertFalse(accounts.isBusy)
    }

    // 동일한 Pro 명칭도 서비스에 맞게 표시하고 캐시의 실제 조회 시각을 보존한다.
    func testClaudePlanAndCachedUsageAge() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let service = TestAccountService(email: "test@example.com")
        let store = fixture.store(service: service, provider: .claude)
        await store.loadLocalAccounts()
        XCTAssertEqual(store.activeAccount?.account.displayPlan, "Pro")
        XCTAssertEqual(store.activeAccount?.refreshedAt, Date(timeIntervalSince1970: 1_000))
    }

    // 일부 조회 실패를 안내해도 서비스가 이미 저장한 성공 결과는 화면에 반영한다.
    func testClaudeRefreshLoadsPartialResultsBeforeShowingError() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let service = TestAccountService(email: "claude@example.com")
        let store = fixture.store(service: service, provider: .claude)
        await store.loadLocalAccounts()
        try await waitUntil { !store.isBusy }
        await service.failRefreshAfterSavingPartialResult()
        store.refresh()
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.activeAccount?.refreshedAt, Date(timeIntervalSince1970: 2_000))
        XCTAssertEqual(store.notice?.style, .error)
    }

    // 1분 자동 조회는 계정 작업 결과 같은 다른 안내를 지우지 않고, 자기가 띄운 오류만 다음 성공 때 지운다.
    func testAutomaticRefreshKeepsOtherNoticesAndClearsOnlyItsOwnError() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let service = TestAccountService(email: "codex@example.com")
        let store = fixture.store(service: service)
        await store.loadLocalAccounts()
        store.notice = AccountStore.Notice(style: .success, message: "전환했습니다.")
        let resultID = try XCTUnwrap(store.notice?.id)
        store.refresh(interactive: false)
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.notice?.id, resultID)

        // 자동 조회가 실패하면 오류를 알리고, 다시 성공하면 그 오류만 지운다.
        await service.setRefreshFailure(true)
        store.refresh(interactive: false)
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.notice?.style, .error)
        await service.setRefreshFailure(false)
        store.refresh(interactive: false)
        try await waitUntil { !store.isBusy }
        XCTAssertNil(store.notice)

        // 직접 누른 새로 고침의 오류는 이후 자동 조회가 성공해도 닫을 때까지 남긴다.
        await service.setRefreshFailure(true)
        store.refresh()
        try await waitUntil { !store.isBusy }
        let manualID = try XCTUnwrap(store.notice?.id)
        await service.setRefreshFailure(false)
        store.refresh(interactive: false)
        try await waitUntil { !store.isBusy }
        XCTAssertEqual(store.notice?.id, manualID)
    }

    // 새로 고침 중에도 계정 작업을 받아 두고, 조회가 결과를 반영한 뒤에 이어서 실행한다.
    func testAccountOperationWaitsForRefreshInsteadOfBeingIgnored() async throws {
        let fixture = Fixture()
        defer { fixture.cleanUp() }
        let service = TestAccountService(email: "codex@example.com")
        let store = fixture.store(service: service)
        await store.loadLocalAccounts()
        store.refresh(interactive: false)
        XCTAssertTrue(store.isRefreshing)
        XCTAssertFalse(store.isAccountOperationBusy)
        store.connectAccount()
        XCTAssertTrue(store.isConnecting)
        try await waitUntil { !store.isBusy }
        let events = await service.events
        XCTAssertEqual(events, ["refresh-start", "refresh-end", "connect"])
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("계정 작업이 완료되지 않았습니다.")
    }

    @MainActor private struct Fixture {
        let suite = "ProviderAccounts-\(UUID().uuidString)"
        let defaults: UserDefaults

        init() {
            defaults = UserDefaults(suiteName: suite)!
            defaults.set(false, forKey: "autoRefreshEnabled")
            defaults.set(false, forKey: "claudeAutoRefreshEnabled")
        }

        func store(service: any AccountService, provider: AccountProvider = .codex) -> AccountStore {
            AccountStore(authService: service, provider: provider, userDefaults: defaults)
        }

        func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    }
}

// 테스트 대역은 네트워크·실제 인증 파일·데스크톱 앱을 사용하지 않는다.
private actor TestAccountService: AccountService {
    let email: String
    private(set) var mutationCount = 0
    private(set) var refreshPolicies: [Bool] = []
    private(set) var creditCalls = 0
    // 조회와 계정 작업이 실제로 실행된 순서다.
    private(set) var events: [String] = []
    private var checkedAt: Int64 = 1_000
    private var shouldFailRefresh = false

    init(email: String) { self.email = email }

    func loadRegistry() -> AccountRegistry {
        AccountRegistry(schemaVersion: 3, activeAccountKey: "same-key", api: nil, accounts: [
            CodexAccount(accountKey: "same-key", email: email, alias: nil, accountName: nil,
                         plan: "pro", authMode: "claude", lastUsedAt: nil, lastUsageAt: checkedAt, lastUsage: nil)
        ])
    }
    func loadOrImportLocalRegistry() -> AccountRegistry { loadRegistry() }
    func refreshAccounts() async throws { try await refreshAccounts(interactive: false) }
    func refreshAccounts(interactive: Bool) async throws {
        refreshPolicies.append(interactive)
        events.append("refresh-start")
        defer { events.append("refresh-end") }
        try await Task.sleep(for: .milliseconds(20))
        if shouldFailRefresh {
            checkedAt = 2_000
            throw ClaudeUsageError.httpFailure(500)
        }
    }
    func failRefreshAfterSavingPartialResult() { shouldFailRefresh = true }
    func setRefreshFailure(_ fails: Bool) { shouldFailRefresh = fails }
    func connectAccount() -> String { mutationCount += 1; events.append("connect"); return "same-key" }
    func switchAccount(accountKey: String) { mutationCount += 1 }
    func removeAccount(accountKey: String, expectedActive: Bool) -> AccountRemovalResult {
        mutationCount += 1
        return AccountRemovalResult(credentialCleanupComplete: true)
    }
    func fetchResetCredits(accountKey: String) -> [ResetCredit] { creditCalls += 1; return [] }
}
