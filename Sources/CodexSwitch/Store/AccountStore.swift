import AppKit
import Foundation

// 메뉴바 패널의 비동기 상태와 사용자 동작을 관리한다.
@MainActor
final class AccountStore: ObservableObject {
    let provider: AccountProvider
    enum NoticeStyle {
        case success
        case warning
        case error
    }

    struct Notice: Identifiable {
        let id = UUID()
        let style: NoticeStyle
        private let messageProvider: () -> String
        var message: String { messageProvider() }

        // 이미 표시 중인 알림도 내용·상태를 유지한 채 선택한 언어로 다시 렌더링한다.
        init(style: NoticeStyle, message: @autoclosure @escaping () -> String) {
            self.style = style
            messageProvider = message
        }
    }

    @Published private(set) var accounts: [AccountListItem] = []
    @Published private(set) var activeAccountKey: String?
    @Published private(set) var resetCreditState: ResetCreditState = .loading
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isRestartingForUpdate = false
    @Published private(set) var switchingAccountKey: String?
    @Published private(set) var removingAccountKey: String?
    @Published var notice: Notice?
    @Published var autoRefreshEnabled: Bool {
        didSet {
            userDefaults.set(autoRefreshEnabled, forKey: autoRefreshPreferenceKey)
            updateAutoRefreshTask()
        }
    }
    @Published var restartChatGPTAfterSwitch: Bool {
        didSet {
            userDefaults.set(
                restartChatGPTAfterSwitch,
                forKey: restartPreferenceKey
            )
        }
    }

    private var autoRefreshPreferenceKey: String {
        provider == .codex ? "autoRefreshEnabled" : "claudeAutoRefreshEnabled"
    }
    private var restartPreferenceKey: String {
        provider == .codex ? "restartCodexAfterSwitch" : "restartClaudeAfterSwitch"
    }
    private let authService: any AccountService
    private let userDefaults: UserDefaults
    private let autoRefreshInterval: Duration
    private let switchRefreshDelay: Duration
    private let appController: ChatGPTAppController
    private var localLoadTask: Task<Void, Never>?
    private var didCompleteInitialLoad = false
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var switchRefreshTask: Task<Void, Never>?
    // 자동 조회가 띄운 오류 안내이며, 다른 작업의 안내와 구분해 자동 조회가 지울 수 있는 것만 가리킨다.
    private var automaticNoticeID: UUID?
    private var autoRefreshTask: Task<Void, Never>?
    private var resetCreditTask: Task<Void, Never>?
    private var resetCreditAccountKey: String?
    private let resetCreditLoader: @Sendable (String) async throws -> [ResetCredit]

    init(
        authService: (any AccountService)? = nil,
        provider: AccountProvider = .codex,
        userDefaults: UserDefaults = .standard,
        autoRefreshInterval: Duration = .seconds(60),
        switchRefreshDelay: Duration = .seconds(5),
        resetCreditLoader: (@Sendable (String) async throws -> [ResetCredit])? = nil
    ) {
        let service: any AccountService = authService
            ?? (provider == .codex ? CodexAuthService() as any AccountService : ClaudeAuthService())
        self.provider = provider
        self.authService = service
        self.appController = ChatGPTAppController(provider: provider)
        self.userDefaults = userDefaults
        self.autoRefreshInterval = autoRefreshInterval
        self.switchRefreshDelay = switchRefreshDelay
        self.resetCreditLoader = resetCreditLoader ?? { key in
            try await service.fetchResetCredits(accountKey: key)
        }
        // 저장된 선택이 없을 때만 자동 갱신을 기본으로 켜고, 사용자가 끈 값은 유지한다.
        let refreshKey = provider == .codex ? "autoRefreshEnabled" : "claudeAutoRefreshEnabled"
        let restartKey = provider == .codex ? "restartCodexAfterSwitch" : "restartClaudeAfterSwitch"
        autoRefreshEnabled = userDefaults.object(forKey: refreshKey) == nil
            || userDefaults.bool(forKey: refreshKey)
        if userDefaults.object(forKey: restartKey) == nil {
            restartChatGPTAfterSwitch = true
        } else {
            restartChatGPTAfterSwitch = userDefaults.bool(
                forKey: restartKey
            )
        }
        updateAutoRefreshTask()
    }

    deinit {
        autoRefreshTask?.cancel()
        switchRefreshTask?.cancel()
        resetCreditTask?.cancel()
    }

    // 앱이 소유한 반복 작업으로 메뉴가 닫혀도 갱신하며, 끄거나 다시 켜면 이전 예약을 취소한다.
    private func updateAutoRefreshTask() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard autoRefreshEnabled else { return }

        autoRefreshTask = Task { [weak self, autoRefreshInterval] in
            guard !Task.isCancelled else { return }
            // Codex의 기존 시작 동작을 유지하고 Claude 인증은 해당 탭을 처음 열 때 가져온다.
            if self?.provider == .codex { await self?.loadLocalAccounts() }
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: autoRefreshInterval)
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                guard let self else { return }
                guard !accounts.isEmpty else { continue }
                // 수동 새로 고침과 같은 조회 설정·busy 보호를 사용해 작업이 겹치지 않게 한다.
                refresh(interactive: false)
            }
        }
    }

    var activeAccount: AccountListItem? {
        accounts.first { $0.account.accountKey == activeAccountKey }
    }

    var isBusy: Bool {
        isAccountOperationBusy || isRefreshing
    }

    // 인증을 바꾸는 작업만 다른 계정 작업을 막고, 새로 고침 중에 요청한 계정 작업은 그 조회가 끝난 뒤 이어서 실행한다.
    var isAccountOperationBusy: Bool {
        isRestartingForUpdate
            || isLoading
            || isConnecting
            || switchingAccountKey != nil
            || removingAccountKey != nil
    }

    // 재시작을 요청한 뒤에는 자동 갱신을 포함한 새 계정 작업이 시작되지 않게 한다.
    func prepareForUpdateRestart() -> Bool {
        guard !isBusy else { return false }
        isRestartingForUpdate = true
        return true
    }

    func cancelUpdateRestart() {
        isRestartingForUpdate = false
    }

    func loadLocalAccounts() async {
        guard !didCompleteInitialLoad else { return }
        if let localLoadTask {
            await localLoadTask.value
            return
        }
        guard !isBusy else { return }
        isLoading = true

        // 메뉴가 닫혀 SwiftUI task가 취소돼도 Store 소유 로드는 끝까지 완료한다.
        let task = Task { [weak self] in
            guard let self else { return }
            defer {
                isLoading = false
                localLoadTask = nil
            }
            do {
                let registry = try await authService.loadOrImportLocalRegistry()
                apply(registry)
            } catch is CancellationError {
                // 앱 종료 중 취소는 사용자 오류로 남기지 않는다.
            } catch {
                notice = Notice(style: .error, message: error.localizedDescription)
            }
        }
        localLoadTask = task
        await task.value
        // Claude는 저장된 기록을 먼저 보여 준 뒤 실시간 값을 이어서 조회해 첫 화면이 서버 응답을 기다리지 않게 한다.
        if provider == .claude, didCompleteInitialLoad, !accounts.isEmpty {
            refresh(interactive: false, keepsNotice: true)
        }
    }

    // keepsNotice는 계정 전환 직후의 자동 조회에서 전환 결과 안내를 지우거나 덮지 않게 한다.
    func refresh(interactive: Bool = true, keepsNotice: Bool = false) {
        guard !isBusy else { return }
        isRefreshing = true
        // 직접 누른 새로 고침만 이전 안내를 지우고, 1분 자동 조회는 계정 작업 결과나 승인 안내를 지우지 않는다.
        if interactive, !keepsNotice { notice = nil }

        // 같은 버튼에서 현재 새로 고침을 취소할 수 있도록 Task를 보관한다.
        refreshTask = Task {
            defer {
                isRefreshing = false
                refreshTask = nil
            }
            do {
                try await authService.refreshAccounts(interactive: interactive)
                let registry = try await authService.loadRegistry()
                apply(registry)
                // 이전 자동 조회가 남긴 오류는 다시 성공하면 지워 지나간 실패가 계속 보이지 않게 한다.
                if let automaticNoticeID, notice?.id == automaticNoticeID { notice = nil }
            } catch is CancellationError {
                notice = Notice(style: .warning, message: L10n.text("새로 고침을 취소했습니다."))
            } catch {
                // Claude 일부 계정만 실패했어도 디스크에 기록된 다른 계정의 성공 결과는 표시한다.
                if provider == .claude, let registry = try? await authService.loadRegistry() {
                    apply(registry)
                }
                if !keepsNotice {
                    let errorNotice = Notice(style: .error, message: error.localizedDescription)
                    notice = errorNotice
                    // 자동 조회의 오류만 기억해 다음 성공 때 지우고, 직접 누른 새로 고침의 오류는 닫을 때까지 둔다.
                    automaticNoticeID = interactive ? nil : errorNotice.id
                }
                // 사용량 helper 조회가 실패해도 별도 쿠폰 API 갱신은 시도한다.
                refreshResetCredits()
            }
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
    }

    // 계정이 바뀐 뒤 새 계정의 사용량을 한 번 조회한다. Claude는 다시 열린 앱이 새 기록을 남길 시간을 두며,
    // 그 사이 다른 작업이 시작됐다면 겹쳐 실행하지 않고 다음 조회에 맡긴다.
    func refreshAfterAccountChange() {
        switchRefreshTask?.cancel()
        let delay = provider == .claude ? switchRefreshDelay : .zero
        switchRefreshTask = Task { [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, !isBusy else { return }
            refresh(interactive: false, keepsNotice: true)
        }
    }

    func switchAccount(to item: AccountListItem) {
        guard !isAccountOperationBusy, item.account.accountKey != activeAccountKey else { return }
        switchingAccountKey = item.account.accountKey
        notice = nil

        Task {
            defer { switchingAccountKey = nil }
            var stopResult = ChatGPTAppController.StopResult.notRunning
            do {
                // 진행 중인 새로 고침이 결과를 반영한 뒤 전환해 전환 후 목록을 이전 조회 결과로 덮지 않는다.
                await refreshTask?.value
                // 실행 중인 앱이 이전 계정 auth를 다시 쓰지 못하도록 먼저 종료한다.
                stopResult = try await appController.stopIfRunning()
                try await authService.switchAccount(
                    accountKey: item.account.accountKey
                )
                let registry = try await authService.loadRegistry()
                apply(registry)
                await finishCredentialChange(
                    displayName: item.account.displayName,
                    action: "전환",
                    stopResult: stopResult
                )
                refreshAfterAccountChange()
            } catch AccountServiceError.credentialRestoreFailed {
                notice = Notice(style: .error, message: AccountServiceError.credentialRestoreFailed.localizedDescription)
            } catch is CancellationError {
                await restoreChatGPTIfNeeded(after: stopResult)
                notice = Notice(style: .warning, message: L10n.text("계정 전환을 취소했습니다."))
            } catch {
                await restoreChatGPTIfNeeded(after: stopResult)
                notice = Notice(style: .error, message: error.localizedDescription)
            }
        }
    }

    func removeAccount(_ item: AccountListItem) {
        guard !isAccountOperationBusy else { return }
        let accountKey = item.account.accountKey
        let wasActive = accountKey == activeAccountKey
        removingAccountKey = accountKey
        notice = nil

        Task {
            defer { removingAccountKey = nil }
            var stopResult = ChatGPTAppController.StopResult.notRunning
            do {
                // 진행 중인 새로 고침이 끝난 뒤 제거해 제거된 계정이 이전 조회 결과로 다시 보이지 않게 한다.
                await refreshTask?.value
                // 비활성 계정 삭제는 실행 중인 ChatGPT 세션을 건드리지 않는다.
                if wasActive {
                    stopResult = try await appController.stopIfRunning()
                }
                let removalResult = try await authService.removeAccount(
                    accountKey: accountKey,
                    expectedActive: wasActive
                )
                let registry = try await authService.loadRegistry()
                apply(registry)

                if wasActive, registry.activeAccountKey != nil {
                    await finishCredentialChange(
                        displayName: item.account.displayName,
                        action: "제거한 뒤 남은 계정으로 전환",
                        stopResult: stopResult
                    )
                    refreshAfterAccountChange()
                } else if wasActive {
                    let closedSuffix: () -> String
                    if case .stopped = stopResult {
                        closedSuffix = { self.provider == .codex
                            ? L10n.text(" ChatGPT는 닫힌 상태입니다.")
                            : L10n.text(" Claude는 닫힌 상태입니다.") }
                    } else {
                        closedSuffix = { "" }
                    }
                    notice = Notice(
                        style: .success,
                        message: self.provider == .codex
                            ? L10n.text("계정을 제거하고 이 Mac의 Codex 인증을 해제했습니다.%@", closedSuffix())
                            : L10n.text("계정을 제거하고 이 Mac의 Claude 인증을 해제했습니다.%@", closedSuffix())
                    )
                } else {
                    notice = Notice(
                        style: .success,
                        message: L10n.text("%@ 계정을 이 Mac에서 제거했습니다.", String(item.account.displayName))
                    )
                }
                applyRemovalCleanupWarningIfNeeded(removalResult)
            } catch is CancellationError {
                await restoreChatGPTIfNeeded(after: stopResult)
                notice = Notice(style: .warning, message: L10n.text("계정 제거를 취소했습니다."))
            } catch AccountServiceError.credentialRestoreFailed {
                if let registry = try? await authService.loadRegistry() { apply(registry) }
                notice = Notice(style: .error, message: AccountServiceError.credentialRestoreFailed.localizedDescription)
            } catch CodexAuthError.credentialRestoreFailed {
                // auth와 registry의 일관성을 보장할 수 없으므로 ChatGPT는 닫힌 채로 둔다.
                if let registry = try? await authService.loadRegistry() {
                    apply(registry)
                }
                notice = Notice(
                    style: .error,
                    message: CodexAuthError.credentialRestoreFailed.localizedDescription
                )
            } catch {
                await restoreChatGPTIfNeeded(after: stopResult)
                // helper 동기화 중 목록이 달라졌다면 화면도 최신 registry로 맞춘다.
                if let registry = try? await authService.loadRegistry() {
                    apply(registry)
                }
                notice = Notice(style: .error, message: error.localizedDescription)
            }
        }
    }

    private func applyRemovalCleanupWarningIfNeeded(_ result: AccountRemovalResult) {
        guard !result.credentialCleanupComplete else { return }
        let completedNotice = notice
        notice = Notice(
            style: .warning,
            message: L10n.text("%@ 일부 로컬 인증 백업을 정리하지 못했습니다. 파일 권한을 확인해 주세요.", completedNotice?.message ?? L10n.text("계정은 제거됐습니다."))
        )
    }

    func connectAccount() {
        guard !isAccountOperationBusy else { return }
        isConnecting = true
        notice = nil
        if provider == .claude {
            notice = Notice(style: .warning, message: L10n.text("Claude에서 새 계정으로 로그인해 주세요. 완료 후 기존 계정으로 돌아옵니다."))
        }

        connectionTask = Task {
            defer {
                isConnecting = false
                connectionTask = nil
            }
            do {
                // 진행 중인 새로 고침이 끝난 뒤 시작해 추가된 계정이 이전 조회 결과로 가려지지 않게 한다.
                await refreshTask?.value
                // 로그인은 격리된 인증 공간에서 진행해 실행 중인 ChatGPT와 현재 계정을 유지한다.
                let connectedAccountKey = try await authService.connectAccount()
                let registry = try await authService.loadRegistry()
                let connectedName = registry.accounts.first {
                    $0.accountKey == connectedAccountKey
                }?.displayName ?? L10n.text("새 계정")
                apply(registry)
                let message = { registry.activeAccountKey == nil
                    ? L10n.text("%@ 계정을 추가했습니다. 사용할 계정을 선택해 주세요.", String(connectedName))
                    : L10n.text("%@ 계정을 추가했습니다. 현재 계정은 그대로 유지됩니다.", String(connectedName)) }
                notice = Notice(
                    style: .success,
                    message: message()
                )
            } catch is CancellationError {
                notice = Notice(style: .warning, message: L10n.text("계정 추가를 취소했습니다."))
            } catch {
                // import가 끝난 뒤 정리 오류가 나도 실제 계정 목록과 화면을 다시 맞춘다.
                if let registry = try? await authService.loadRegistry() {
                    apply(registry)
                }
                notice = Notice(style: .error, message: error.localizedDescription)
            }
        }
    }

    func cancelConnection() {
        connectionTask?.cancel()
    }

    func dismissNotice() {
        notice = nil
    }

    func quit() {
        guard !isBusy else { return }
        NSApplication.shared.terminate(nil)
    }

    private func apply(_ registry: AccountRegistry) {
        activeAccountKey = registry.activeAccountKey
        // 조회와 읽기가 성공한 뒤에만 기록하며 사용량이 같아도 완료 시각은 갱신한다.
        let refreshedAt = Date()
        accounts = registry.accounts.map { account in
            // Claude API 캐시는 실제 성공한 조회 시각을 표시해 오래된 값을 방금 조회한 것처럼 보이지 않는다.
            let timestamp = provider == .claude
                ? account.lastUsageAt.map { Date(timeIntervalSince1970: Double($0)) }
                : refreshedAt
            return AccountListItem(account: account, refreshedAt: timestamp)
        }
        didCompleteInitialLoad = true
        refreshResetCredits()
    }

    // 사용량 모드와 독립적으로 조회하며 이전 요청이 늦게 끝나도 새 계정 화면을 덮지 않는다.
    private func refreshResetCredits() {
        resetCreditTask?.cancel()
        resetCreditTask = nil
        guard provider == .codex else {
            resetCreditState = .loaded([])
            return
        }
        // 같은 계정의 갱신 중에는 마지막 쿠폰을 유지하고, 계정 변경 시에만 이전 결과를 지운다.
        if resetCreditAccountKey != activeAccountKey || resetCreditState == .failed {
            resetCreditState = .loading
        }
        resetCreditAccountKey = activeAccountKey
        guard let key = activeAccountKey, activeAccount != nil else { return }
        let loader = resetCreditLoader
        resetCreditTask = Task { [weak self] in
            do {
                let credits = try await loader(key)
                guard !Task.isCancelled, let self, activeAccountKey == key else { return }
                resetCreditState = .loaded(credits)
            } catch {
                guard !Task.isCancelled, let self, activeAccountKey == key else { return }
                resetCreditState = .failed
            }
        }
    }

    #if DEBUG
    // XCTest 렌더 검증에서만 실제 registry와 같은 샘플 상태를 주입한다.
    func applyPreviewRegistry(_ registry: AccountRegistry) {
        apply(registry)
    }
    #endif

    private func finishCredentialChange(
        displayName: String,
        action: String,
        stopResult: ChatGPTAppController.StopResult
    ) async {
        guard restartChatGPTAfterSwitch else {
            let message: () -> String
            if case .stopped = stopResult {
                message = { self.provider == .codex
                    ? L10n.text("%@ 계정을 %@했습니다. ChatGPT는 닫힌 상태입니다.", String(displayName), L10n.text(action))
                    : L10n.text("%@ 계정을 %@했습니다. Claude는 닫힌 상태입니다.", String(displayName), L10n.text(action)) }
            } else {
                message = { L10n.text("%@ 계정을 %@했습니다.", String(displayName), L10n.text(action)) }
            }
            notice = Notice(
                style: .success,
                message: message()
            )
            return
        }

        do {
            let preferredURL: URL?
            if case let .stopped(url) = stopResult {
                preferredURL = url
            } else {
                preferredURL = nil
            }
            let didOpenChatGPT = try await appController.open(preferredURL: preferredURL)
            notice = Notice(
                style: .success,
                message: didOpenChatGPT
                    ? (self.provider == .codex
                        ? L10n.text("%@ 계정을 %@하고 ChatGPT를 열었습니다.", String(displayName), L10n.text(action))
                        : L10n.text("%@ 계정을 %@하고 Claude를 열었습니다.", String(displayName), L10n.text(action)))
                    : L10n.text("%@ 계정을 %@했습니다.", String(displayName), L10n.text(action))
            )
        } catch {
            notice = Notice(
                style: .warning,
                message: L10n.text("계정은 %@됐습니다. %@", L10n.text(action), String(error.localizedDescription))
            )
        }
    }

    private func restoreChatGPTIfNeeded(
        after stopResult: ChatGPTAppController.StopResult
    ) async {
        guard case let .stopped(url) = stopResult else { return }
        _ = try? await appController.open(preferredURL: url)
    }

}
