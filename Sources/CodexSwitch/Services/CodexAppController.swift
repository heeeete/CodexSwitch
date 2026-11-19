import AppKit

// 자격 증명 변경 전에 선택한 데스크톱 앱을 정상 종료하고 필요할 때 다시 연다.
@MainActor
struct ChatGPTAppController {
    let provider: AccountProvider

    init(provider: AccountProvider = .codex) { self.provider = provider }

    enum StopResult: Sendable {
        case stopped(URL)
        case notRunning
    }

    enum RestartError: LocalizedError {
        case couldNotQuit
        case missingBundleURL
        case claudeCouldNotQuit
        case claudeMissingBundleURL

        var errorDescription: String? {
            switch self {
            case .couldNotQuit:
                return L10n.text("ChatGPT가 종료되지 않았습니다. 직접 종료한 뒤 다시 열어 주세요.")
            case .missingBundleURL:
                return L10n.text("ChatGPT 앱 위치를 찾지 못했습니다. 직접 다시 열어 주세요.")
            case .claudeCouldNotQuit:
                return L10n.text("Claude가 종료되지 않았습니다. 직접 종료한 뒤 다시 시도해 주세요.")
            case .claudeMissingBundleURL:
                return L10n.text("Claude 앱 위치를 찾지 못했습니다. Claude를 설치한 뒤 다시 시도해 주세요.")
            }
        }
    }

    func stopIfRunning() async throws -> StopResult {
        try Task.checkCancellation()
        guard let chatGPTApp = runningChatGPTApplication() else {
            guard runningApplications.isEmpty else { throw couldNotQuit }
            return .notRunning
        }
        guard let bundleURL = chatGPTApp.bundleURL else {
            throw provider == .codex ? RestartError.missingBundleURL : RestartError.claudeMissingBundleURL
        }
        guard chatGPTApp.terminate() else {
            throw couldNotQuit
        }

        // 종료 요청 뒤에는 취소와 무관하게 결과를 확인해 호출자가 재실행할 URL을 잃지 않게 한다.
        // Codex는 기존처럼 3초, 보조 프로세스까지 기다리는 Claude는 8초까지 확인한다.
        for _ in 0..<(provider == .codex ? 30 : 80) where !chatGPTApp.isTerminated || !runningApplications.isEmpty {
            await waitIgnoringTaskCancellation(for: 0.1)
        }
        guard chatGPTApp.isTerminated, runningApplications.isEmpty else {
            throw couldNotQuit
        }

        return .stopped(bundleURL)
    }

    private func waitIgnoringTaskCancellation(for seconds: TimeInterval) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }

    func open(preferredURL: URL? = nil) async throws -> Bool {
        // CLI-only 환경은 정상 지원하므로 열 ChatGPT가 없으면 실패로 취급하지 않는다.
        guard let bundleURL = preferredURL ?? installedChatGPTURL() else {
            return false
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        try await NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration
        )
        return true
    }

    private func runningChatGPTApplication() -> NSRunningApplication? {
        // 이름이 아닌 공식 번들 ID로만 찾아 다른 Codex 관련 앱을 종료하지 않는다.
        NSRunningApplication.runningApplications(
            withBundleIdentifier: provider.bundleIdentifier
        ).first
    }

    private func installedChatGPTURL() -> URL? {
        if let workspaceURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: provider.bundleIdentifier
        ) {
            return workspaceURL
        }

        let systemURL = URL(fileURLWithPath: "/Applications/\(provider.appName).app", isDirectory: true)
        return FileManager.default.fileExists(atPath: systemURL.path) ? systemURL : nil
    }

    // Chromium Helper가 쿠키 DB를 붙잡고 있으면 인증 파일을 교체하지 않는다.
    // 쿠키를 바꾸지 않는 Codex는 남아 있는 보조 프로세스 때문에 전환이 막히지 않도록 본 앱만 확인한다.
    private var runningApplications: [NSRunningApplication] {
        guard provider == .claude else { return [] }
        return NSWorkspace.shared.runningApplications.filter {
            guard let identifier = $0.bundleIdentifier else { return false }
            return !$0.isTerminated && (identifier == provider.bundleIdentifier
                || identifier.hasPrefix(provider.bundleIdentifier + "."))
        }
    }

    private var couldNotQuit: RestartError {
        provider == .codex ? .couldNotQuit : .claudeCouldNotQuit
    }
}
