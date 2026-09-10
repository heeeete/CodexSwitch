import AppKit
import Foundation

// 메뉴바 패널의 비동기 상태와 사용자 동작을 관리한다.
@MainActor
final class AccountStore: ObservableObject {
    enum NoticeStyle {
        case success
        case warning
        case error
    }

    struct Notice: Identifiable {
        let id = UUID()
        let style: NoticeStyle
        let message: String
    }

    @Published private(set) var accounts: [AccountListItem] = []
    @Published private(set) var activeAccountKey: String?
    @Published private(set) var isLoading = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var isConnecting = false
    @Published private(set) var isRestartingForUpdate = false
    @Published private(set) var switchingAccountKey: String?
    @Published private(set) var removingAccountKey: String?
    @Published var notice: Notice?
    @Published var autoRefreshEnabled: Bool {
        didSet {
            userDefaults.set(autoRefreshEnabled, forKey: Self.autoRefreshPreferenceKey)
            updateAutoRefreshTask()
        }
    }
    @Published var restartChatGPTAfterSwitch: Bool {
        didSet {
            userDefaults.set(
                restartChatGPTAfterSwitch,
                forKey: Self.restartPreferenceKey
            )
        }
    }
    @Published private(set) var directAPIRefreshEnabled: Bool {
        didSet {
            userDefaults.set(
                directAPIRefreshEnabled,
                forKey: Self.directAPIRefreshPreferenceKey
            )
        }
    }

    private static let autoRefreshPreferenceKey = "autoRefreshEnabled"
    private static let restartPreferenceKey = "restartCodexAfterSwitch"
    private static let directAPIRefreshPreferenceKey = "directAPIRefreshEnabled"
    private let authService: CodexAuthService
    private let userDefaults: UserDefaults
    private let autoRefreshInterval: Duration
    private let appController = ChatGPTAppController()
    private var localLoadTask: Task<Void, Never>?
    private var didCompleteInitialLoad = false
    private var connectionTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var autoRefreshTask: Task<Void, Never>?

    init(
        authService: CodexAuthService = CodexAuthService(),
        userDefaults: UserDefaults = .standard,
        autoRefreshInterval: Duration = .seconds(60)
    ) {
        self.authService = authService
        self.userDefaults = userDefaults
        self.autoRefreshInterval = autoRefreshInterval
        // 저장된 선택이 없을 때만 자동 갱신을 기본으로 켜고, 사용자가 끈 값은 유지한다.
        autoRefreshEnabled = userDefaults.object(forKey: Self.autoRefreshPreferenceKey) == nil
            || userDefaults.bool(forKey: Self.autoRefreshPreferenceKey)
        if userDefaults.object(forKey: Self.restartPreferenceKey) == nil {
            restartChatGPTAfterSwitch = true
        } else {
            restartChatGPTAfterSwitch = userDefaults.bool(
                forKey: Self.restartPreferenceKey
            )
        }
        directAPIRefreshEnabled = userDefaults.bool(
            forKey: Self.directAPIRefreshPreferenceKey
        )
        updateAutoRefreshTask()
    }

    deinit {
        autoRefreshTask?.cancel()
    }

    // 앱이 소유한 반복 작업으로 메뉴가 닫혀도 갱신하며, 끄거나 다시 켜면 이전 예약을 취소한다.
    private func updateAutoRefreshTask() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard autoRefreshEnabled else { return }

        autoRefreshTask = Task { [weak self, autoRefreshInterval] in
            guard !Task.isCancelled else { return }
            // 저장된 설정으로 앱을 시작해도 메뉴를 열기 전에 계정을 준비한다.
            await self?.loadLocalAccounts()
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
                refresh()
            }
        }
    }

    var activeAccount: AccountListItem? {
        accounts.first { $0.account.accountKey == activeAccountKey }
    }

    var isBusy: Bool {
        isRestartingForUpdate
            || isLoading
            || isRefreshing
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
    }

    func refresh() {
        guard !isBusy else { return }
        isRefreshing = true
        notice = nil

        // 같은 버튼에서 현재 새로 고침을 취소할 수 있도록 Task를 보관한다.
        refreshTask = Task {
            defer {
                isRefreshing = false
                refreshTask = nil
            }
            do {
                try await authService.refreshAccounts(
                    useDirectAPI: directAPIRefreshEnabled
                )
                let registry = try await authService.loadRegistry()
                apply(registry)
            } catch is CancellationError {
                notice = Notice(style: .warning, message: "새로 고침을 취소했습니다.")
            } catch {
                notice = Notice(style: .error, message: error.localizedDescription)
            }
        }
    }

    func cancelRefresh() {
        refreshTask?.cancel()
    }

    func switchAccount(to item: AccountListItem) {
        guard !isBusy, item.account.accountKey != activeAccountKey else { return }
        switchingAccountKey = item.account.accountKey
        notice = nil

        Task {
            defer { switchingAccountKey = nil }
            var stopResult = ChatGPTAppController.StopResult.notRunning
            do {
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
            } catch is CancellationError {
                await restoreChatGPTIfNeeded(after: stopResult)
                notice = Notice(style: .warning, message: "계정 전환을 취소했습니다.")
            } catch {
                await restoreChatGPTIfNeeded(after: stopResult)
                notice = Notice(style: .error, message: error.localizedDescription)
            }
        }
    }

    func removeAccount(_ item: AccountListItem) {
        guard !isBusy else { return }
        let accountKey = item.account.accountKey
        let wasActive = accountKey == activeAccountKey
        removingAccountKey = accountKey
        notice = nil

        Task {
            defer { removingAccountKey = nil }
            var stopResult = ChatGPTAppController.StopResult.notRunning
            do {
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
                } else if wasActive {
                    let closedSuffix: String
                    if case .stopped = stopResult {
                        closedSuffix = " ChatGPT는 닫힌 상태입니다."
                    } else {
                        closedSuffix = ""
                    }
                    notice = Notice(
                        style: .success,
                        message: "계정을 제거하고 이 Mac의 Codex 인증을 해제했습니다.\(closedSuffix)"
                    )
                } else {
                    notice = Notice(
                        style: .success,
                        message: "\(item.account.displayName) 계정을 이 Mac에서 제거했습니다."
                    )
                }
                applyRemovalCleanupWarningIfNeeded(removalResult)
            } catch is CancellationError {
                await restoreChatGPTIfNeeded(after: stopResult)
                notice = Notice(style: .warning, message: "계정 제거를 취소했습니다.")
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
        let completedMessage = notice?.message ?? "계정은 제거됐습니다."
        notice = Notice(
            style: .warning,
            message: "\(completedMessage) 일부 로컬 인증 백업을 정리하지 못했습니다. 파일 권한을 확인해 주세요."
        )
    }

    func connectAccount() {
        guard !isBusy else { return }
        isConnecting = true
        notice = nil

        connectionTask = Task {
            defer {
                isConnecting = false
                connectionTask = nil
            }
            do {
                // 로그인은 격리된 인증 공간에서 진행해 실행 중인 ChatGPT와 현재 계정을 유지한다.
                let connectedAccountKey = try await authService.connectAccount()
                let registry = try await authService.loadRegistry()
                let connectedName = registry.accounts.first {
                    $0.accountKey == connectedAccountKey
                }?.displayName ?? "새 계정"
                apply(registry)
                let message = registry.activeAccountKey == nil
                    ? "\(connectedName) 계정을 추가했습니다. 사용할 계정을 선택해 주세요."
                    : "\(connectedName) 계정을 추가했습니다. 현재 계정은 그대로 유지됩니다."
                notice = Notice(
                    style: .success,
                    message: message
                )
            } catch is CancellationError {
                notice = Notice(style: .warning, message: "계정 추가를 취소했습니다.")
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

    // 비공개 API 위험을 명확히 확인한 뒤에만 정확한 원격 조회를 켠다.
    func setDirectAPIRefreshEnabled(_ enabled: Bool) {
        guard enabled != directAPIRefreshEnabled else { return }
        guard enabled else {
            directAPIRefreshEnabled = false
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "실험적 API 조회를 켤까요?"
        alert.informativeText = "새로 고칠 때 codex-auth가 액세스 토큰으로 OpenAI의 비공개 ChatGPT 사용량·워크스페이스 API를 직접 호출합니다. 토큰이 로컬 프로세스 인자에 잠시 노출될 수 있고, upstream은 이용약관 위반이나 계정 제한 가능성을 경고합니다. 기본 로컬 조회가 더 안전합니다."
        alert.addButton(withTitle: "위험을 이해하고 켜기")
        alert.addButton(withTitle: "취소")

        if alert.runModal() == .alertFirstButtonReturn {
            directAPIRefreshEnabled = true
        }
    }

    func quit() {
        guard !isBusy else { return }
        NSApplication.shared.terminate(nil)
    }

    private func apply(_ registry: AccountRegistry) {
        activeAccountKey = registry.activeAccountKey
        // 조회와 읽기가 성공한 뒤에만 기록하며 사용량이 같아도 완료 시각은 갱신한다.
        let refreshedAt = Date()
        accounts = registry.accounts.map { AccountListItem(account: $0, refreshedAt: refreshedAt) }
        didCompleteInitialLoad = true
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
            let message: String
            if case .stopped = stopResult {
                message = "\(displayName) 계정을 \(action)했습니다. ChatGPT는 닫힌 상태입니다."
            } else {
                message = "\(displayName) 계정을 \(action)했습니다."
            }
            notice = Notice(
                style: .success,
                message: message
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
                    ? "\(displayName) 계정을 \(action)하고 ChatGPT를 열었습니다."
                    : "\(displayName) 계정을 \(action)했습니다."
            )
        } catch {
            notice = Notice(
                style: .warning,
                message: "계정은 \(action)됐습니다. \(error.localizedDescription)"
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
