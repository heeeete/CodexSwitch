import AppKit
import SwiftUI

// 설치가 끝난 실행본에서만 계정 조회와 Sparkle를 시작한다.
@MainActor
final class AppStartup: NSObject, ObservableObject, NSApplicationDelegate, NSWindowDelegate {
    @Published private(set) var isReady = false
    @Published private(set) var installationError: String?
    @Published private(set) var isInstalling = false
    lazy var accountStore = AccountStore()
    lazy var updateStore = UpdateStore(
        startAutomatically: true,
        prepareForRestart: { [weak self] in self?.accountStore.prepareForUpdateRestart() ?? false },
        restartCancelled: { [weak self] in self?.accountStore.cancelUpdateRestart() }
    )
    private var installationWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        // 개발 실행본은 설치하지 않아 로컬 빌드가 사용 중인 앱을 교체하지 않는다.
        startRuntime()
        #else
        installOrStart()
        #endif
    }

    func installOrStart() {
        guard !isInstalling else { return }
        let installer = AppInstaller(sourceURL: Bundle.main.bundleURL)
        if installer.isInstalled {
            startRuntime()
            return
        }
        showInstallationWindow()
        installationError = nil
        isInstalling = true
        Task {
            do {
                // 이미 실행 중인 앱의 계정 작업을 끊거나 두 앱에서 동시에 실행하지 않는다.
                let otherApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier!)
                    .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier && !$0.isTerminated }
                guard otherApps.isEmpty else {
                    showInstallationError("실행 중인 CodexSwitch의 메뉴에서 ‘종료’를 누른 뒤 다시 시도해 주세요.")
                    return
                }
                let installation = try await Task.detached { try installer.install() }.value
                do {
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.createsNewApplicationInstance = true
                    let launched = try await NSWorkspace.shared.openApplication(
                        at: installation.applicationURL, configuration: configuration
                    )
                    guard launched.bundleURL?.resolvingSymlinksInPath().path == installation.applicationURL.resolvingSymlinksInPath().path else {
                        throw AppInstaller.InstallationError.invalidApp
                    }
                } catch {
                    try installation.restoreBackup()
                    throw error
                }
                installation.finish()
                NSApp.terminate(nil)
            } catch {
                NSLog("CodexSwitch installation failed: %@", error.localizedDescription)
                showInstallationError((error as? AppInstaller.InstallationError)?.localizedDescription
                    ?? "설치를 마치지 못했어요. Finder에서 앱을 응용 프로그램 폴더로 옮긴 뒤 다시 실행해 주세요.")
            }
        }
    }

    private func startRuntime() {
        _ = accountStore
        _ = updateStore
        isReady = true
    }

    func showInstallationError(_ message: String) {
        installationError = message
        isInstalling = false
    }

    // 설치가 필요한 첫 실행에서만 작고 고정된 네이티브 창을 앞으로 가져온다.
    private func showInstallationWindow() {
        if installationWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 330),
                styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false
            )
            window.title = "CodexSwitch 설치"
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.isMovableByWindowBackground = true
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.contentView = NSHostingView(rootView: InstallationView(startup: self))
            window.center()
            installationWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        installationWindow?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { !isInstalling }
    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}
