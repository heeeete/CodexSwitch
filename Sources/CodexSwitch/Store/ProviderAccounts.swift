import Combine
import Foundation

// 두 서비스의 작업 상태를 함께 관찰하고 마지막 조회 탭만 저장한다.
@MainActor
final class ProviderAccounts: ObservableObject {
    let codex: AccountStore
    let claude: AccountStore
    @Published private(set) var selectedProvider: AccountProvider
    private let defaults: UserDefaults
    private var observations: [AnyCancellable] = []
    private static let selectionKey = "selectedAccountProvider"

    init(
        codex: AccountStore? = nil,
        claude: AccountStore? = nil,
        userDefaults: UserDefaults = .standard,
        initialProvider: AccountProvider? = nil
    ) {
        defaults = userDefaults
        self.codex = codex ?? AccountStore(userDefaults: userDefaults)
        self.claude = claude ?? AccountStore(provider: .claude, userDefaults: userDefaults)
        selectedProvider = initialProvider
            ?? AccountProvider(rawValue: userDefaults.string(forKey: Self.selectionKey) ?? "")
            ?? .codex
        for store in [self.codex, self.claude] {
            observations.append(store.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            })
        }
    }

    var selectedStore: AccountStore { selectedProvider == .codex ? codex : claude }
    var isBusy: Bool { codex.isBusy || claude.isBusy }
    // 1분마다 도는 새로 고침은 탭과 계정 메뉴를 잠그지 않도록 인증을 바꾸는 작업만 따로 모은다.
    var isAccountOperationBusy: Bool { codex.isAccountOperationBusy || claude.isAccountOperationBusy }
    var isRestartingForUpdate: Bool { codex.isRestartingForUpdate || claude.isRestartingForUpdate }

    // 계정 작업 중에는 대상을 고정해 열린 하위 메뉴가 다른 서비스에 적용되지 않게 한다.
    func select(_ provider: AccountProvider) {
        guard !isAccountOperationBusy, selectedProvider != provider else { return }
        selectedProvider = provider
        defaults.set(provider.rawValue, forKey: Self.selectionKey)
        Task { await selectedStore.loadLocalAccounts() }
    }

    // 업데이트와 종료는 어느 탭에서 시작한 계정 작업이든 끝날 때까지 기다린다.
    func prepareForUpdateRestart() -> Bool {
        guard !isBusy else { return false }
        guard codex.prepareForUpdateRestart() else { return false }
        guard claude.prepareForUpdateRestart() else {
            codex.cancelUpdateRestart()
            return false
        }
        return true
    }

    func cancelUpdateRestart() {
        codex.cancelUpdateRestart()
        claude.cancelUpdateRestart()
    }
}
