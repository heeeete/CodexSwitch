import AppKit
import Sparkle
import SwiftUI
import XCTest
@testable import CodexSwitch

@MainActor
final class UpdateStoreTests: XCTestCase {
    // 다운로드·검증 완료 안내는 정확한 문구를 쓰고 클릭 전에는 설치하지 않는다.
    func testReadyUpdateWaitsForClickAndInstallsOnlyOnce() {
        let store = UpdateStore()
        let driver = UpdateUserDriver(store: store)
        var installations = 0
        driver.showReady { choice in
            XCTAssertEqual(choice, .install)
            installations += 1
        }
        XCTAssertEqual(store.status, .ready)
        XCTAssertEqual(store.message, "새로운 업데이트가 있어요! 다시 시작할까요?")
        XCTAssertEqual(store.actionTitle, "다시 시작")
        XCTAssertEqual(installations, 0)
        store.performAction()
        store.performAction()
        XCTAssertEqual(installations, 1)
        XCTAssertEqual(store.status, .installing)
    }

    // 진행 중인 계정 작업이 있으면 재시작 콜백을 보존하고 작업이 끝난 뒤 설치한다.
    func testBusyAccountWorkDefersRestart() {
        var busy = true
        let store = UpdateStore(prepareForRestart: { !busy })
        let driver = UpdateUserDriver(store: store)
        var installed = false
        driver.showReady { _ in installed = true }
        store.performAction()
        XCTAssertFalse(installed)
        XCTAssertEqual(store.status, .ready)
        busy = false
        store.performAction()
        XCTAssertTrue(installed)
    }

    // 검증·설치 실패 후에는 이전 설치 콜백을 다시 실행하지 않고 재시작 잠금을 해제한다.
    func testFailureClearsInstallationAndUnlocksAccountWork() {
        var unlocked = false
        let store = UpdateStore(restartCancelled: { unlocked = true })
        let driver = UpdateUserDriver(store: store)
        var installed = false
        var acknowledged = false
        driver.showReady { _ in installed = true }
        driver.showUpdaterError(NSError(domain: "UpdateTest", code: 1)) { acknowledged = true }
        XCTAssertTrue(acknowledged)
        XCTAssertTrue(unlocked)
        XCTAssertEqual(store.status, .failed)
        XCTAssertEqual(store.actionTitle, "다시 시도")
        store.performAction()
        XCTAssertFalse(installed)
        driver.dismissUpdateInstallation()
        XCTAssertEqual(store.status, .failed)
    }

    // 새 버전이 없거나 설치 세션을 취소하면 하단 안내와 이전 콜백을 정리한다.
    func testDismissedUpdateDoesNotLeaveRestartAction() {
        let store = UpdateStore()
        let driver = UpdateUserDriver(store: store)
        var installed = false
        driver.showReady { _ in installed = true }
        driver.dismissUpdateInstallation()
        store.performAction()
        XCTAssertFalse(installed)
        XCTAssertEqual(store.status, .idle)
        XCTAssertNil(store.actionTitle)
        var acknowledged = false
        driver.showUpdateNotFoundWithError(NSError(domain: "UpdateTest", code: 2)) {
            acknowledged = true
        }
        XCTAssertTrue(acknowledged)
        XCTAssertEqual(store.status, .idle)
    }

    // 수동 확인 결과는 설정에 남기고 메뉴에는 불필요한 최신 버전 안내를 만들지 않는다.
    func testManualCheckShowsProgressAndLatestVersionWithoutMenuNotice() {
        let store = UpdateStore()
        let driver = UpdateUserDriver(store: store)
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        XCTAssertEqual(store.checkMessage, "업데이트를 확인하고 있어요.")
        XCTAssertEqual(store.status, .idle)
        driver.showUpdateNotFoundWithError(NSError(domain: SUSparkleErrorDomain, code: 1001)) {}
        driver.dismissUpdateInstallation()
        XCTAssertEqual(store.checkMessage, "최신 버전을 사용하고 있어요.")
        XCTAssertEqual(store.status, .idle)
        driver.showUserInitiatedUpdateCheck(cancellation: {})
        driver.showUpdaterError(NSError(domain: NSURLErrorDomain, code: -1009)) {}
        XCTAssertEqual(store.checkMessage, "")
        XCTAssertEqual(store.status, .failed)
    }

    // 기본 설정과 재시작 안내가 밝은·어두운 네이티브 폼 안에 들어가는지 확인한다.
    func testSettingsLayoutInBothAppearances() throws {
        for scheme in [ColorScheme.light, .dark] {
            let updates = UpdateStore()
            let driver = UpdateUserDriver(store: updates)
            for ready in [false, true] {
                if ready { driver.showReady { _ in } }
                let view = NSHostingView(rootView:
                    SettingsView(updateStore: updates, accountStore: AccountStore())
                        .environment(\.colorScheme, scheme)
                )
                let size = view.fittingSize
                XCTAssertEqual(size.width, 460, accuracy: 1)
                XCTAssertGreaterThan(size.height, 160)
                XCTAssertLessThan(size.height, 450)
                if let root = ProcessInfo.processInfo.environment["CODEXSWITCH_SETTINGS_SNAPSHOT_ROOT"] {
                    view.frame = NSRect(origin: .zero, size: size)
                    view.layoutSubtreeIfNeeded()
                    let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                    try data.write(to: URL(fileURLWithPath: "\(root)-\(scheme)-\(ready).png"))
                }
            }
        }
    }

    // 재시작을 요청한 뒤에는 새 계정 작업이 시작되지 않고 실패 시 정상 복구된다.
    func testRestartLockPreventsAccountMutations() {
        let accounts = AccountStore()
        XCTAssertTrue(accounts.prepareForUpdateRestart())
        XCTAssertTrue(accounts.isBusy)
        accounts.refresh()
        accounts.connectAccount()
        XCTAssertFalse(accounts.isRefreshing)
        XCTAssertFalse(accounts.isConnecting)
        XCTAssertFalse(accounts.prepareForUpdateRestart())
        accounts.cancelUpdateRestart()
        XCTAssertFalse(accounts.isBusy)
    }

    // 메뉴 하단에 안내가 추가돼도 밝은·어두운 화면에서 글자가 잘리지 않는다.
    func testUpdateNoticeLayoutFitsMenuInBothAppearances() throws {
        let updates = UpdateStore()
        let driver = UpdateUserDriver(store: updates)
        driver.showReady { _ in }
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView:
                UpdateNoticeView(updateStore: updates, isBusy: false)
                    .frame(width: 372)
                    .background(scheme == .dark ? Color.black : Color.white)
                    .environment(\.colorScheme, scheme)
            )
            let size = view.fittingSize
            XCTAssertEqual(size.width, 372, accuracy: 1)
            XCTAssertGreaterThan(size.height, 55)
            XCTAssertLessThan(size.height, 110)
            if let snapshotRoot = ProcessInfo.processInfo.environment["CODEXSWITCH_UPDATE_SNAPSHOT_ROOT"] {
                view.frame = NSRect(origin: .zero, size: size)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "\(snapshotRoot)-\(scheme).png"))
            }
        }
    }
}
