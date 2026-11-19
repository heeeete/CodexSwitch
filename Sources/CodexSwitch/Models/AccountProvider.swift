import Foundation

// 탭은 조회할 서비스를 고르며 각 서비스의 실제 로그인 상태는 따로 유지한다.
enum AccountProvider: String, CaseIterable, Identifiable, Sendable {
    case codex, claude

    var id: String { rawValue }
    var title: String { self == .codex ? "Codex" : "Claude" }
    var appName: String { self == .codex ? "ChatGPT" : "Claude" }
    var bundleIdentifier: String {
        self == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop"
    }
}
