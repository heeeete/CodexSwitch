import AppKit
import Combine

// 실제 인증정보나 설치된 CodexSwitch를 쓰지 않고 Sparkle의 앱 교체·재실행을 검증한다.
@MainActor
final class UpdateFixtureDelegate: NSObject, NSApplicationDelegate {
    private let updates = UpdateStore()
    private var observation: AnyCancellable?
    private var didRequestRestart = false

    private var resultDirectory: URL {
        URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "UpdateTestResultDirectory") as! String)
    }

    private func record(_ name: String, _ text: String = "") {
        try? Data(text.utf8).write(to: resultDirectory.appendingPathComponent(name), options: .atomic)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String == "4" {
            record("passed", "새 앱으로 교체하고 재실행했습니다.")
            NSApp.terminate(nil)
            return
        }
        observation = updates.$status.sink { [weak self] status in
            guard let self else { return }
            if status == .ready, !didRequestRestart {
                didRequestRestart = true
                // 준비 상태에서 기다려도 앱이 스스로 재시작하지 않고 버튼 동작 뒤에만 교체되어야 한다.
                Task { [weak self] in
                    guard let self else { return }
                    // Published의 willSet 알림이 끝난 뒤 화면과 같은 확정 상태를 읽는다.
                    record("ready", updates.message)
                    try? await Task.sleep(for: .seconds(2))
                    record("clicked")
                    updates.performAction()
                }
            } else if status == .failed {
                record("failed", "업데이트 준비 또는 설치 실패")
                NSApp.terminate(nil)
            }
        }
        updates.start()
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(100))
            self?.record("failed", "업데이트 대기 시간 초과")
            NSApp.terminate(nil)
        }
    }
}

@main
enum UpdateFixture {
    @MainActor
    static func main() {
        let delegate = UpdateFixtureDelegate()
        let app = NSApplication.shared
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
