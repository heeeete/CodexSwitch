import AppKit

// 자격 증명 변경 전에 공식 ChatGPT를 정상 종료하고 필요할 때 다시 연다.
@MainActor
struct ChatGPTAppController {
    enum StopResult: Sendable {
        case stopped(URL)
        case notRunning
    }

    enum RestartError: LocalizedError {
        case couldNotQuit
        case missingBundleURL

        var errorDescription: String? {
            switch self {
            case .couldNotQuit:
                return "ChatGPT가 종료되지 않았습니다. 직접 종료한 뒤 다시 열어 주세요."
            case .missingBundleURL:
                return "ChatGPT 앱 위치를 찾지 못했습니다. 직접 다시 열어 주세요."
            }
        }
    }

    func stopIfRunning() async throws -> StopResult {
        try Task.checkCancellation()
        guard let chatGPTApp = runningChatGPTApplication() else {
            return .notRunning
        }
        guard let bundleURL = chatGPTApp.bundleURL else {
            throw RestartError.missingBundleURL
        }
        guard chatGPTApp.terminate() else {
            throw RestartError.couldNotQuit
        }

        // 종료 요청 뒤에는 취소와 무관하게 결과를 확인해 호출자가 재실행할 URL을 잃지 않게 한다.
        for _ in 0..<30 where !chatGPTApp.isTerminated {
            await waitIgnoringTaskCancellation(for: 0.1)
        }
        guard chatGPTApp.isTerminated else {
            throw RestartError.couldNotQuit
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
            withBundleIdentifier: "com.openai.codex"
        ).first
    }

    private func installedChatGPTURL() -> URL? {
        if let workspaceURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.openai.codex"
        ) {
            return workspaceURL
        }

        let systemURL = URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        return FileManager.default.fileExists(atPath: systemURL.path) ? systemURL : nil
    }
}
