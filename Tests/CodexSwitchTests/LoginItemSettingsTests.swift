import ServiceManagement
import XCTest
@testable import CodexSwitch

@MainActor
final class LoginItemSettingsTests: XCTestCase {
    // 실제 로그인 항목을 건드리지 않고 최초 등록·사용자 해제·승인 대기·실패 상태를 검증한다.
    func testDefaultRegistrationRespectsSystemStateAndUserChoice() throws {
        let suite = "CodexSwitch-LoginItem-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var systemStatus = SMAppService.Status.notRegistered
        var changes: [Bool] = []
        var shouldFail = false
        func settings() -> LoginItemSettings {
            LoginItemSettings(defaults: defaults, readStatus: { systemStatus }, updateRegistration: { enabled in
                changes.append(enabled)
                if shouldFail { throw NSError(domain: "LoginItemTest", code: 1) }
                systemStatus = enabled ? .enabled : .notRegistered
            })
        }
        let firstLaunch = settings()
        firstLaunch.enableByDefault()
        firstLaunch.enableByDefault()
        XCTAssertEqual(changes, [true])
        XCTAssertEqual(firstLaunch.status, .enabled)

        firstLaunch.setEnabled(false)
        settings().enableByDefault()
        XCTAssertEqual(changes, [true, false])
        XCTAssertEqual(systemStatus, .notRegistered)

        // 시스템 설정에서 해제한 상태도 다음 실행에서 다시 켜지 않는다.
        firstLaunch.setEnabled(true)
        systemStatus = .requiresApproval
        firstLaunch.refresh()
        settings().enableByDefault()
        XCTAssertEqual(firstLaunch.status, .requiresApproval)
        XCTAssertEqual(changes, [true, false, true])

        // 기존 등록·승인 대기는 최초 기본값 적용 시에도 그대로 둔다.
        for existingStatus in [SMAppService.Status.enabled, .requiresApproval] {
            defaults.removePersistentDomain(forName: suite)
            systemStatus = existingStatus
            settings().enableByDefault()
            XCTAssertEqual(systemStatus, existingStatus)
            XCTAssertEqual(changes.count, 3)
        }

        systemStatus = .notRegistered
        shouldFail = true
        firstLaunch.setEnabled(true)
        XCTAssertTrue(firstLaunch.hasError)
        XCTAssertEqual(firstLaunch.status, .notRegistered)
        shouldFail = false
        firstLaunch.setEnabled(true)
        XCTAssertFalse(firstLaunch.hasError)
        XCTAssertEqual(firstLaunch.status, .enabled)
    }
}
