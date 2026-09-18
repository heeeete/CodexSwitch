import Combine
import ServiceManagement

// 저장된 켜짐 값 대신 macOS의 실제 로그인 항목 상태를 표시한다.
@MainActor
final class LoginItemSettings: ObservableObject {
    static let shared = LoginItemSettings()
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var hasError = false
    private let defaults: UserDefaults
    private let readStatus: () -> SMAppService.Status
    private let updateRegistration: (Bool) throws -> Void

    init(defaults: UserDefaults = .standard,
         readStatus: @escaping () -> SMAppService.Status = { SMAppService.mainApp.status },
         updateRegistration: @escaping (Bool) throws -> Void = { enabled in
             if enabled { try SMAppService.mainApp.register() }
             else { try SMAppService.mainApp.unregister() }
         }) {
        self.defaults = defaults
        self.readStatus = readStatus
        self.updateRegistration = updateRegistration
        status = readStatus()
    }

    // 첫 실행에만 기본 등록하며 앱이나 시스템 설정에서 끈 선택을 덮어쓰지 않는다.
    func enableByDefault() {
        refresh()
        guard !defaults.bool(forKey: "loginItemDefaultApplied") else { return }
        defaults.set(true, forKey: "loginItemDefaultApplied")
        if status == .notRegistered { setEnabled(true) }
    }

    func refresh() {
        status = readStatus()
    }

    func setEnabled(_ enabled: Bool) {
        defaults.set(true, forKey: "loginItemDefaultApplied")
        refresh()
        // 사용자가 시스템 설정에서 막았다면 등록을 반복하지 않고 해당 설정을 연다.
        if enabled && status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()
            return
        }
        do {
            if enabled != (status == .enabled) { try updateRegistration(enabled) }
            hasError = false
        } catch {
            hasError = true
            NSLog("CodexSwitch login item change failed: %@", error.localizedDescription)
        }
        refresh()
    }
}
