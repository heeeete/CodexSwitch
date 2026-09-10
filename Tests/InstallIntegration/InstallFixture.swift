import AppKit

// 실제 계정과 Applications를 쓰지 않고 서명된 앱의 복사·새 위치 재실행을 확인한다.
@MainActor
final class InstallFixtureDelegate: NSObject, NSApplicationDelegate {
    private let root = URL(fileURLWithPath: Bundle.main.object(forInfoDictionaryKey: "InstallationTestRoot") as! String)

    func applicationDidFinishLaunching(_ notification: Notification) {
        let installer = AppInstaller(
            sourceURL: Bundle.main.bundleURL,
            systemApplicationsURL: root.appendingPathComponent("Applications"),
            userApplicationsURL: root.appendingPathComponent("UserApplications")
        )
        if installer.isInstalled {
            try? Data(Bundle.main.bundleURL.resolvingSymlinksInPath().path.utf8)
                .write(to: root.appendingPathComponent("installed"), options: .atomic)
            NSApp.terminate(nil)
            return
        }
        Task {
            do {
                // 첫 실행을 허용받은 다운로드 앱처럼 격리 속성이 남은 상태에서 설치를 시작한다.
                var source = Bundle.main.bundleURL
                var values = URLResourceValues()
                values.quarantineProperties = ["LSQuarantineType": "LSQuarantineTypeOtherDownload"]
                try source.setResourceValues(values)
                let installation = try await Task.detached { try installer.install() }.value
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.createsNewApplicationInstance = true
                let application = try await NSWorkspace.shared.openApplication(
                    at: installation.applicationURL, configuration: configuration
                )
                guard application.bundleURL?.resolvingSymlinksInPath().path == installation.applicationURL.resolvingSymlinksInPath().path else {
                    throw AppInstaller.InstallationError.invalidApp
                }
                installation.finish()
                try Data().write(to: root.appendingPathComponent("relaunched"))
            } catch {
                try? Data(error.localizedDescription.utf8).write(to: root.appendingPathComponent("failed"))
            }
            NSApp.terminate(nil)
        }
    }
}

@main
enum InstallFixture {
    @MainActor
    static func main() {
        let delegate = InstallFixtureDelegate()
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.accessory)
        application.run()
        withExtendedLifetime(delegate) {}
    }
}
