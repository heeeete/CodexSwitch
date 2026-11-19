import Foundation

// 서비스별 인증 저장 방식만 분리하고 기존 계정 화면과 비동기 상태를 재사용한다.
protocol AccountService: Sendable {
    func loadRegistry() async throws -> AccountRegistry
    func loadOrImportLocalRegistry() async throws -> AccountRegistry
    func refreshAccounts() async throws
    func refreshAccounts(interactive: Bool) async throws
    func connectAccount() async throws -> String
    func switchAccount(accountKey: String) async throws
    func removeAccount(accountKey: String, expectedActive: Bool) async throws -> AccountRemovalResult
    func fetchResetCredits(accountKey: String) async throws -> [ResetCredit]
}

extension AccountService {
    func refreshAccounts(interactive: Bool) async throws {
        try await refreshAccounts()
    }

    func fetchResetCredits(accountKey: String) async throws -> [ResetCredit] { [] }
}

extension CodexAuthService: AccountService {}

// 인증 복구가 실패한 경우 앱을 다시 열어 불완전한 인증을 읽게 하지 않는다.
enum AccountServiceError: LocalizedError {
    case credentialRestoreFailed

    var errorDescription: String? {
        L10n.text("Claude 인증을 원래 상태로 복구하지 못했습니다. Claude를 열지 말고 로컬 백업을 확인해 주세요.")
    }
}
