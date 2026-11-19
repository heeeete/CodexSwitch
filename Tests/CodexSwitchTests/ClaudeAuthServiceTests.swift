import AppKit
import Foundation
import SQLite3
import XCTest
@testable import CodexSwitch

@MainActor
final class ClaudeAuthServiceTests: XCTestCase {
    private let firstID = "11111111-1111-4111-8111-111111111111"
    private let secondID = "22222222-2222-4222-8222-222222222222"
    private let personalOrg = "55555555-5555-4555-8555-555555555555"
    private let sharedOrg = "66666666-6666-4666-8666-666666666666"

    // Claude가 없는 첫 실행에는 디스크·키체인·앱 실행에 영향을 주지 않는다.
    func testMissingDesktopReturnsEmptyWithoutCreatingStorage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let service = fixture.service()
        let registry = try await service.loadOrImportLocalRegistry()
        XCTAssertTrue(registry.accounts.isEmpty)
        XCTAssertNil(registry.activeAccountKey)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storage.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.desktop.path))
        XCTAssertEqual(fixture.runtime.openCount, 0)
        XCTAssertEqual(fixture.runtime.stopCount, 0)
    }

    // 실행 중인 기존 계정도 메타데이터와 사용량을 가져오되 앱을 닫지 않는다.
    func testImportsLiveAccountAndUsageWithoutRestartingDesktop() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        fixture.runtime.running = true
        AuthTestURLProtocol.reset()
        let service = fixture.service()
        // 첫 로드는 서버를 기다리지 않고 계정만 등록하며, 이어지는 조회가 메타데이터와 사용량을 채운다.
        let imported = try await service.loadOrImportLocalRegistry()
        XCTAssertEqual(imported.activeAccountKey, firstID)
        XCTAssertNil(imported.accounts.first?.lastUsage)
        XCTAssertEqual(AuthTestURLProtocol.requestCount(), 0)
        try await service.refreshAccounts(interactive: false)
        let registry = try await service.loadRegistry()
        XCTAssertEqual(registry.activeAccountKey, firstID)
        XCTAssertEqual(registry.accounts.first?.email, "\(firstID)@example.com")
        XCTAssertEqual(registry.accounts.first?.authMode, "claude")
        XCTAssertEqual(registry.accounts.first?.lastUsage?.primary?.usedPercent, 25)
        XCTAssertEqual(registry.accounts.first?.lastUsage?.secondary?.usedPercent, 60)
        XCTAssertEqual(fixture.runtime.stopCount, 0)
        XCTAssertTrue(fixture.runtime.running)
        let attributes = try FileManager.default.attributesOfItem(atPath: fixture.storage.appendingPathComponent("registry.json").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    // 인증·쿠키를 함께 바꾸고 기존 설정과 직전 계정의 최신 로그인은 보존한다.
    func testSwitchesBothCredentialStoresAndPreservesSharedSettings() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try Data("old-journal".utf8).write(to: fixture.desktop.appendingPathComponent("Cookies-journal"))
        try fixture.saveRegistry([firstID, secondID])
        try fixture.saveSnapshot(secondID, cookies: "cookies-second")
        let service = fixture.service()
        try await service.switchAccount(accountKey: secondID)
        let config = try fixture.config()
        XCTAssertEqual(config["lastKnownAccountUuid"] as? String, secondID)
        XCTAssertEqual(config["oauth:tokenCacheV2"] as? String, secondID)
        XCTAssertEqual(config["locale"] as? String, "ko-KR")
        XCTAssertEqual(config["zoom"] as? Double, 1.25)
        XCTAssertEqual(try String(contentsOf: fixture.desktop.appendingPathComponent("Cookies"), encoding: .utf8), "cookies-second")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("Cookies-journal").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.snapshotURL(firstID).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storage.appendingPathComponent("recovery.json").path))
        let registry = try await service.loadRegistry()
        XCTAssertEqual(registry.activeAccountKey, secondID)
        try await service.switchAccount(accountKey: firstID)
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, firstID)
        XCTAssertEqual(try String(contentsOf: fixture.desktop.appendingPathComponent("Cookies-journal"), encoding: .utf8), "old-journal")
    }

    // 타깃 UUID가 다른 인증과 실행 중인 앱은 실제 파일을 바꾸기 전에 거부한다.
    func testRejectsMismatchedSnapshotAndRunningDesktop() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID])
        try fixture.saveSnapshot(secondID, cookies: "cookies-second", authID: firstID)
        let service = fixture.service()
        do {
            try await service.switchAccount(accountKey: secondID)
            XCTFail("다른 계정 스냅샷을 허용했습니다.")
        } catch {}
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, firstID)
        try fixture.saveSnapshot(secondID, cookies: "cookies-second")
        fixture.runtime.running = true
        do {
            try await service.switchAccount(accountKey: secondID)
            XCTFail("실행 중인 Claude의 인증을 변경했습니다.")
        } catch {}
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, firstID)
    }

    // 중간에 프로세스가 종료된 전환은 다음 읽기에서 보관된 원본 인증으로 복구한다.
    func testRecoversInterruptedCredentialReplacement() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID])
        let originalRegistry = try Data(contentsOf: fixture.storage.appendingPathComponent("registry.json"))
        let recovery: [String: Any] = [
            "snapshot": try fixture.snapshot(firstID, cookies: "cookies-first"),
            "registry": originalRegistry.base64EncodedString()
        ]
        try JSONSerialization.data(withJSONObject: recovery).write(to: fixture.storage.appendingPathComponent("recovery.json"))
        try fixture.setLive(secondID, cookies: "half-written-cookies")
        let registry = try await fixture.service().loadOrImportLocalRegistry()
        XCTAssertEqual(registry.activeAccountKey, firstID)
        XCTAssertEqual(try String(contentsOf: fixture.desktop.appendingPathComponent("Cookies"), encoding: .utf8), "cookies-first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storage.appendingPathComponent("recovery.json").path))
    }

    // 새 계정 추가는 로그인한 계정만 저장하고 로그인 전 활성 계정으로 돌아온다.
    func testConnectAccountPreservesOriginalDesktopLogin() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID])
        fixture.runtime.accountOnFirstOpen = secondID
        let service = fixture.service()
        let connected = try await service.connectAccount()
        XCTAssertEqual(connected, secondID)
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, firstID)
        XCTAssertEqual(try String(contentsOf: fixture.desktop.appendingPathComponent("Cookies"), encoding: .utf8), "cookies-first")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.snapshotURL(secondID).path))
        let registry = try await service.loadRegistry()
        XCTAssertEqual(Set(registry.accounts.map(\.id)), Set([firstID, secondID]))
        XCTAssertEqual(registry.activeAccountKey, firstID)
        XCTAssertEqual(fixture.runtime.stopCount, 2)
        XCTAssertEqual(fixture.runtime.openCount, 2)
    }

    // 일반 데스크톱 로그인만 완료해 Code OAuth가 없어도 추가와 이후 사용량 조회가 끝난다.
    func testCookieOnlyDesktopLoginCompletesAndRefreshesUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID])
        fixture.runtime.accountOnFirstOpen = secondID
        fixture.runtime.cookieOnlyLogin = true
        let service = fixture.service()
        let connected = try await service.connectAccount()
        XCTAssertEqual(connected, secondID)
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, firstID)
        let snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.snapshotURL(secondID))) as! [String: Any]
        XCTAssertNil((snapshot["auth"] as? [String: Any])?["oauth:tokenCacheV2"])
        fixture.runtime.stop()
        try await service.switchAccount(accountKey: secondID)
        try await service.refreshAccounts(interactive: true)
        let registry = try await service.loadRegistry()
        let account = try XCTUnwrap(registry.accounts.first { $0.id == secondID })
        XCTAssertEqual(account.email, "\(secondID)@example.com")
        XCTAssertEqual(account.lastUsage?.primary?.usedPercent, 25)
        XCTAssertEqual(account.lastUsage?.secondary?.usedPercent, 60)
    }

    // 로그인 대기 취소도 원래 세션을 복원하고 새 계정이나 복구 파일을 남기지 않는다.
    func testCancellingLoginRestoresOriginalSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID])
        let service = fixture.service()
        let task = Task { try await service.connectAccount() }
        for _ in 0..<100 where fixture.runtime.openCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(fixture.runtime.openCount, 1)
        task.cancel()
        do { _ = try await task.value; XCTFail("로그인 취소를 성공 처리했습니다.") }
        catch is CancellationError {}
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, firstID)
        XCTAssertEqual(fixture.runtime.openCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storage.appendingPathComponent("recovery.json").path))
    }

    // 마지막 계정을 지워도 앱 설정은 유지하며 실제 Claude 계정 삭제 요청은 하지 않는다.
    func testRemovingLastAccountClearsOnlyLocalSignIn() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID])
        try fixture.saveSnapshot(firstID, cookies: "cookies-first")
        let service = fixture.service()
        let result = try await service.removeAccount(accountKey: firstID, expectedActive: true)
        XCTAssertTrue(result.credentialCleanupComplete)
        XCTAssertNil(try fixture.config()["lastKnownAccountUuid"])
        XCTAssertNil(try fixture.config()["oauth:tokenCacheV2"])
        XCTAssertEqual(try fixture.config()["locale"] as? String, "ko-KR")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("Cookies").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.snapshotURL(firstID).path))
        let registry = try await service.loadRegistry()
        XCTAssertTrue(registry.accounts.isEmpty)
        XCTAssertNil(registry.activeAccountKey)
    }

    // 비활성 스냅샷이 없더라도 활성 계정의 갱신 결과를 UI에 전달한다.
    func testInactiveMissingSnapshotDoesNotBlockActiveUsageRefresh() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID])
        let service = fixture.service()
        try await service.refreshAccounts(interactive: true)
        let registry = try await service.loadRegistry()
        XCTAssertEqual(registry.accounts.first?.lastUsage?.primary?.usedPercent, 25)
        XCTAssertEqual(registry.accounts.first?.email, "\(firstID)@example.com")
        XCTAssertNil(registry.accounts.last?.lastUsage)
    }

    // 다시 추가한 동일 계정은 중복 항목을 만들지 않고 없어진 인증 스냅샷을 복구한다.
    func testReconnectingExistingAccountRepairsMissingSnapshot() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID])
        fixture.runtime.accountOnFirstOpen = secondID
        let service = fixture.service()
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.snapshotURL(secondID).path))
        let connected = try await service.connectAccount()
        XCTAssertEqual(connected, secondID)
        let registry = try await service.loadRegistry()
        XCTAssertEqual(registry.accounts.count, 2)
        XCTAssertEqual(registry.activeAccountKey, firstID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.snapshotURL(secondID).path))
    }

    // 표시 UUID만 바꾼 스냅샷은 암호화 캐시의 계정과 대조하여 적용 전에 거부한다.
    func testSwitchRejectsCredentialCacheBoundToAnotherAccount() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID])
        try fixture.saveSnapshot(secondID, cookies: "cookies-second")
        let url = fixture.snapshotURL(secondID)
        var snapshot = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        var auth = snapshot["auth"] as! [String: String]
        auth["oauth:tokenCacheV2"] = try JSONEncoder().encode(firstID).base64EncodedString()
        snapshot["auth"] = auth
        try JSONSerialization.data(withJSONObject: snapshot).write(to: url)
        do {
            try await fixture.service().switchAccount(accountKey: secondID)
            XCTFail("다른 계정의 인증 캐시를 적용했습니다.")
        } catch ClaudeUsageError.invalidCredential {}
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, firstID)
        XCTAssertEqual(try String(contentsOf: fixture.desktop.appendingPathComponent("Cookies"), encoding: .utf8), "cookies-first")
    }

    // 데스크톱 기록만으로 표시할 때는 키체인 승인도 네트워크 요청도 필요하지 않다.
    func testShowsDesktopRecordWithoutKeychainOrNetwork() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.linkOrganization(personalOrg, to: firstID)
        let recordedAt = Int64(Date().timeIntervalSince1970) - 600
        try fixture.writeHistory([(recordedAt, personalOrg, ["fh": 0, "sd": 40])])
        AuthTestURLProtocol.reset()
        let service = fixture.service(keychainAvailable: false)
        let registry = try await service.loadOrImportLocalRegistry()
        let account = try XCTUnwrap(registry.accounts.first)
        XCTAssertEqual(account.usageMeters.map(\.remainingPercent), [100, 60])
        XCTAssertEqual(account.lastUsageAt, recordedAt)
        XCTAssertTrue(account.usageIssues.isEmpty)
        XCTAssertEqual(AuthTestURLProtocol.requestCount(), 0)

        // 자동 갱신은 키체인 미승인을 오류로 알리지 않고, 새 표본이 없으면 기록 시각을 유지한다.
        try await service.refreshAccounts(interactive: false)
        do {
            try await service.refreshAccounts(interactive: true)
            XCTFail("수동 조회의 키체인 실패를 숨겼습니다.")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .keychainUnavailable)
        }
        let refreshed = try await firstAccount(service)
        XCTAssertEqual(refreshed.lastUsageAt, recordedAt)
        XCTAssertEqual(refreshed.lastUsage?.secondary?.usedPercent, 40)
        XCTAssertEqual(AuthTestURLProtocol.requestCount(), 0)
    }

    // 기록이 없고 첫 조회도 실패하면 두 원인을 모두 남기며, 유효한 표본이 생기면 새로고침으로 복구된다.
    func testFirstLoadFailureKeepsCauseAndRecoversWithRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.linkOrganization(personalOrg, to: firstID)
        let service = fixture.service(keychainAvailable: false)
        func issues() async throws -> [ClaudeUsageError] {
            try await service.loadRegistry().accounts.first?.usageIssues.compactMap { $0 as? ClaudeUsageError } ?? []
        }
        let registry = try await service.loadOrImportLocalRegistry()
        XCTAssertEqual(registry.accounts.count, 1)
        XCTAssertNil(registry.accounts.first?.lastUsage)
        XCTAssertEqual(registry.accounts.first?.usageIssues.compactMap { $0 as? ClaudeUsageError }, [.noLocalRecord])
        do { try await service.refreshAccounts(interactive: false); XCTFail("표시할 값이 없는 실패를 숨겼습니다.") } catch {}
        let first = try await issues()
        XCTAssertEqual(first, [.noLocalRecord, .keychainUnavailable])

        // 미지원 버전과 값이 빈 기록은 파일 없음과 다른 이유로 안내한다.
        try Data(#"{"version":9,"samples":[]}"#.utf8).write(to: fixture.desktop.appendingPathComponent("plan-usage-history.json"))
        do { try await service.refreshAccounts(interactive: false); XCTFail("표시할 값이 없는 실패를 숨겼습니다.") } catch {}
        let unsupported = try await issues()
        XCTAssertEqual(unsupported, [.unsupportedLocalRecord, .keychainUnavailable])
        // 데스크톱이 한도 없이 기록한 계정은 구독 없음만 안내하고 자동 조회 실패를 반복해서 알리지 않는다.
        try fixture.writeHistory([(100, personalOrg, [:])])
        try await service.refreshAccounts(interactive: false)
        let unsubscribed = try await firstAccount(service)
        XCTAssertEqual(unsubscribed.usageIssues.compactMap { $0 as? ClaudeUsageError }, [.notSubscribed])
        XCTAssertEqual(unsubscribed.displayPlan, "Free")

        let recordedAt = Int64(Date().timeIntervalSince1970) - 60
        try fixture.writeHistory([(100, personalOrg, [:]), (recordedAt, personalOrg, ["sd": 40])])
        try await service.refreshAccounts(interactive: false)
        let recovered = try await firstAccount(service)
        XCTAssertNil(recovered.lastUsage?.primary)
        XCTAssertEqual(recovered.usageMeters.map(\.remainingPercent), [60])
        XCTAssertTrue(recovered.usageIssues.isEmpty)
    }

    // 조직을 함께 쓰는 계정끼리 사용량이 섞이지 않고, 주인을 알 수 없는 기록은 이유를 안내한다.
    func testAccountsSharingOrganizationDoNotMixUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID])
        try fixture.linkOrganization(personalOrg, to: firstID)
        try fixture.linkOrganization(sharedOrg, to: firstID)
        try fixture.linkOrganization(sharedOrg, to: secondID)
        let now = Int64(Date().timeIntervalSince1970)
        try fixture.writeHistory([(now - 300, personalOrg, ["fh": 10, "sd": 20]), (now - 100, sharedOrg, ["fh": 70, "sd": 80])])
        let service = fixture.service(keychainAvailable: false)
        do { try await service.refreshAccounts(interactive: false) } catch {}
        var accounts = try await service.loadRegistry().accounts
        XCTAssertEqual(accounts[0].lastUsage?.secondary?.usedPercent, 20)
        XCTAssertNil(accounts[1].lastUsage)
        XCTAssertEqual(accounts[1].usageIssues.first as? ClaudeUsageError, .ambiguousOrganization)

        // 데스크톱 로그로 불러온 계정이 확인되면 공유 조직의 기록도 그 계정에만 붙는다.
        try fixture.writeLog([(now - 200, secondID, sharedOrg)])
        do { try await service.refreshAccounts(interactive: false) } catch {}
        accounts = try await service.loadRegistry().accounts
        XCTAssertEqual(accounts[0].lastUsage?.secondary?.usedPercent, 20)
        XCTAssertEqual(accounts[0].lastUsageAt, now - 300)
        XCTAssertEqual(accounts[1].lastUsage?.primary?.usedPercent, 70)
        XCTAssertEqual(accounts[1].lastUsage?.secondary?.usedPercent, 80)
        XCTAssertEqual(accounts[1].lastUsageAt, now - 100)
    }

    // 온라인 값은 오래된 표본으로 덮지 않고, 더 새로운 표본은 유효한 초기화 시각을 이어받는다.
    func testNewerSourceWinsAndKeepsValidResetTime() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.linkOrganization(personalOrg, to: firstID)
        let now = Int64(Date().timeIntervalSince1970)
        try fixture.writeHistory([(now - 120, personalOrg, ["fh": 1, "sd": 2])])
        try await fixture.service().refreshAccounts(interactive: true)
        let online = try await firstAccount(fixture.service())
        XCTAssertEqual(online.lastUsage?.primary?.usedPercent, 25)
        XCTAssertEqual(online.lastUsage?.primary?.resetsAt, 4_070_908_800)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(online.lastUsageAt), now)

        // 일시적 실패 뒤에는 이전 성공값과 시각을 유지하고, 그 뒤의 표본만 반영한다.
        let offline = fixture.service(keychainAvailable: false)
        try await offline.refreshAccounts(interactive: false)
        let kept = try await firstAccount(offline)
        XCTAssertEqual(kept.lastUsage?.primary?.usedPercent, 25)
        XCTAssertEqual(kept.lastUsageAt, online.lastUsageAt)
        try fixture.writeHistory([(now + 30, personalOrg, ["fh": 33, "sd": 61])])
        try await offline.refreshAccounts(interactive: false)
        let newer = try await firstAccount(offline)
        XCTAssertEqual(newer.lastUsage?.primary?.usedPercent, 33)
        XCTAssertEqual(newer.lastUsage?.secondary?.usedPercent, 61)
        XCTAssertEqual(newer.lastUsage?.primary?.resetsAt, 4_070_908_800)
        XCTAssertEqual(newer.lastUsageAt, now + 30)
        XCTAssertEqual(newer.email, "\(firstID)@example.com")
    }

    // 모델별 주간 한도는 실시간 조회로만 알 수 있어, 같은 주간 기간의 데스크톱 표본이 들어와도 마지막 값을 유지한다.
    func testModelWeeklyLimitIsKeptUntilItsReset() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.linkOrganization(personalOrg, to: firstID)
        let now = Int64(Date().timeIntervalSince1970)
        let reset = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: Double(now + 3_600)))
        AuthTestURLProtocol.reset(usage: [
            "five_hour": ["utilization": 25, "resets_at": "2099-01-01T00:00:00Z"],
            "seven_day": ["utilization": 60, "resets_at": "2099-01-05T00:00:00Z"],
            "limits": [["group": "weekly", "kind": "weekly_scoped", "percent": 11, "resets_at": reset,
                        "scope": ["model": ["display_name": "Fable"]]]]
        ])
        try await fixture.service().refreshAccounts(interactive: true)
        let online = try await firstAccount(fixture.service())
        XCTAssertEqual(online.lastUsage?.scoped?.map(\.scope), ["Fable"])
        XCTAssertEqual(online.lastUsage?.scoped?.first?.usedPercent, 11)
        XCTAssertEqual(online.lastUsage?.scoped?.first?.resetsAt, now + 3_600)

        // 같은 기간 안의 새 표본은 두 기간만 바꾸고 모델별 한도는 그대로 둔다.
        let offline = fixture.service(keychainAvailable: false)
        try fixture.writeHistory([(now + 30, personalOrg, ["fh": 33, "sd": 61])])
        try await offline.refreshAccounts(interactive: false)
        let kept = try await firstAccount(offline)
        XCTAssertEqual(kept.lastUsage?.secondary?.usedPercent, 61)
        XCTAssertEqual(kept.lastUsage?.scoped?.first?.usedPercent, 11)

        // 모델별 한도가 초기화된 뒤의 표본에는 지난 기간의 값을 붙이지 않는다.
        try fixture.writeHistory([(now + 7_200, personalOrg, ["fh": 1, "sd": 2])])
        try await offline.refreshAccounts(interactive: false)
        let afterReset = try await firstAccount(offline)
        XCTAssertEqual(afterReset.lastUsage?.secondary?.usedPercent, 2)
        XCTAssertNil(afterReset.lastUsage?.scoped)
    }

    // 초기화 시각이 없는 오래된 기록은 기간별로 숨기고, 모두 지났으면 마지막 기록 시각을 이유로 보여 준다.
    func testStaleRecordIsHiddenPerWindowWithReason() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.linkOrganization(personalOrg, to: firstID)
        let now = Int64(Date().timeIntervalSince1970)
        try fixture.writeHistory([(now - 6 * 3_600, personalOrg, ["fh": 50, "sd": 40])])
        let service = fixture.service(keychainAvailable: false)
        let partial = try await firstAccount(service, importing: true)
        XCTAssertNil(partial.lastUsage?.primary)
        XCTAssertEqual(partial.usageMeters.map(\.remainingPercent), [60])
        XCTAssertEqual(partial.lastUsageAt, now - 6 * 3_600)

        let old = fixture.service(keychainAvailable: false)
        try fixture.saveRegistry([firstID])
        try fixture.writeHistory([(now - 8 * 86_400, personalOrg, ["fh": 50, "sd": 40])])
        let stale = try await firstAccount(old, importing: true)
        XCTAssertNil(stale.lastUsage)
        XCTAssertEqual(stale.usageIssues.compactMap { $0 as? ClaudeUsageError },
                       [.staleLocalRecord(Date(timeIntervalSince1970: Double(now - 8 * 86_400)))])
    }

    // 서버가 두 기간을 모두 제공하지 않으면 계정 정보는 갱신하고 그 사실을 오류 없이 안내한다.
    func testServerWithoutUsageUpdatesProfileAndExplains() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        AuthTestURLProtocol.reset(usage: ["five_hour": NSNull(), "seven_day": NSNull()])
        defer { AuthTestURLProtocol.reset() }
        let service = fixture.service()
        try await service.refreshAccounts(interactive: true)
        let account = try await firstAccount(service)
        XCTAssertEqual(account.email, "\(firstID)@example.com")
        XCTAssertNil(account.lastUsage)
        XCTAssertEqual(account.usageIssues.compactMap { $0 as? ClaudeUsageError }, [.usageNotProvided])
    }

    // 서버가 유료 요금제도 사용량도 알려 주지 않으면 구독하지 않은 계정으로 기록하고 그 사실만 보여 준다.
    func testAccountWithoutSubscriptionIsLabelledClearly() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        AuthTestURLProtocol.reset(usage: ["five_hour": NSNull(), "seven_day": NSNull()], organizationType: "claude_free")
        defer { AuthTestURLProtocol.reset() }
        try await fixture.service().refreshAccounts(interactive: true)
        let verified = try await firstAccount(fixture.service())
        XCTAssertEqual(verified.email, "\(firstID)@example.com")
        XCTAssertEqual(verified.displayPlan, "Free")
        XCTAssertNil(verified.lastUsage)

        // 이후 키체인 승인 없이 조회가 실패해도 저장된 구독 상태로 같은 안내만 유지한다.
        let offline = fixture.service(keychainAvailable: false)
        try fixture.linkOrganization(personalOrg, to: firstID)
        try fixture.writeHistory([(100, personalOrg, [:])])
        try await offline.refreshAccounts(interactive: false)
        let account = try await firstAccount(offline)
        XCTAssertEqual(account.displayPlan, "Free")
        XCTAssertEqual(account.usageIssues.compactMap { $0 as? ClaudeUsageError }, [.notSubscribed])
    }

    // 현재 계정에 표시할 값이 있으면 사용량이 없는 다른 계정의 키체인 미승인도 자동 갱신에서 오류로 알리지 않는다.
    func testAutomaticRefreshStaysQuietWhenActiveAccountHasRecord() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID])
        try fixture.saveSnapshot(secondID, cookies: "cookies-second")
        try fixture.linkOrganization(personalOrg, to: firstID)
        try fixture.writeHistory([(Int64(Date().timeIntervalSince1970) - 60, personalOrg, ["fh": 10, "sd": 20])])
        let service = fixture.service(keychainAvailable: false)
        try await service.refreshAccounts(interactive: false)
        let accounts = try await service.loadRegistry().accounts
        XCTAssertEqual(accounts[0].lastUsage?.secondary?.usedPercent, 20)
        XCTAssertEqual(accounts[1].usageIssues.compactMap { $0 as? ClaudeUsageError }, [.noLocalRecord, .keychainUnavailable])
    }

    // 조회 제한은 보여 줄 값이 없을 때만 알리고, 직전 값이 남아 있으면 수동 갱신에서도 그 값을 유지한 채 넘어간다.
    func testRateLimitIsQuietWhileUsageIsShown() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        defer { AuthTestURLProtocol.reset() }

        // 처음부터 제한되면 보여 줄 값이 없어 그 이유를 알린다.
        AuthTestURLProtocol.reset(status: 429)
        do {
            try await fixture.service().refreshAccounts(interactive: true)
            XCTFail("보여 줄 값이 없으면 조회 제한을 알려야 한다")
        } catch ClaudeUsageError.rateLimited {}

        // 한 번 조회한 뒤의 제한은 오류 없이 직전 값을 그대로 둔다.
        AuthTestURLProtocol.reset()
        try await fixture.service().refreshAccounts(interactive: true)
        AuthTestURLProtocol.reset(status: 429)
        let limited = fixture.service()
        try await limited.refreshAccounts(interactive: true)
        let account = try await firstAccount(limited)
        XCTAssertEqual(account.lastUsage?.primary?.usedPercent, 25)
        XCTAssertEqual(account.lastUsage?.secondary?.usedPercent, 60)
        XCTAssertTrue(account.usageIssues.isEmpty)
    }

    // 계정별 실시간 조회를 동시에 보내 계정 수만큼 차례로 기다리지 않는다.
    func testRefreshQueriesAccountsConcurrently() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID])
        try fixture.saveSnapshot(secondID, cookies: "cookies-second")
        AuthTestURLProtocol.reset(delay: 0.15)
        defer { AuthTestURLProtocol.reset() }
        let service = fixture.service()
        try await service.refreshAccounts(interactive: true)
        XCTAssertEqual(AuthTestURLProtocol.requestCount(), 4)
        XCTAssertGreaterThanOrEqual(AuthTestURLProtocol.peakRequests(), 2)
        let registry = try await service.loadRegistry()
        XCTAssertEqual(registry.accounts.map(\.id), [firstID, secondID])
        XCTAssertEqual(registry.accounts.map { $0.lastUsage?.primary?.usedPercent }, [25, 25])
        XCTAssertEqual(registry.accounts.map(\.email), ["\(firstID)@example.com", "\(secondID)@example.com"])
    }

    // 계정 확인을 기다리는 동안 Claude가 다시 열리면 실행 중인 앱의 인증과 쿠키를 교체하지 않는다.
    func testSwitchStopsWhenClaudeRelaunchesDuringVerification() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID])
        try fixture.saveSnapshot(secondID, cookies: "cookies-second")
        fixture.relaunchDuringVerification = true
        do {
            try await fixture.service().switchAccount(accountKey: secondID)
            XCTFail("다시 열린 Claude의 인증을 교체했습니다.")
        } catch ClaudeAuthError.appRunning {}
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, firstID)
        XCTAssertEqual(try String(contentsOf: fixture.desktop.appendingPathComponent("Cookies"), encoding: .utf8), "cookies-first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storage.appendingPathComponent("recovery.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.snapshotURL(firstID).path))
    }

    // 활성 계정을 지울 때 저장된 로그인이 있는 계정으로 넘어가고, 없으면 실패하지 않고 로그인만 해제한다.
    func testRemovingActiveAccountFallsBackToRestorableAccount() async throws {
        let thirdID = "77777777-7777-4777-8777-777777777777"
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID, secondID, thirdID])
        try fixture.saveSnapshot(thirdID, cookies: "cookies-third")
        let service = fixture.service()
        _ = try await service.removeAccount(accountKey: firstID, expectedActive: true)
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, thirdID)
        XCTAssertEqual(try String(contentsOf: fixture.desktop.appendingPathComponent("Cookies"), encoding: .utf8), "cookies-third")
        var registry = try await service.loadRegistry()
        XCTAssertEqual(registry.accounts.map(\.id), [secondID, thirdID])
        XCTAssertEqual(registry.activeAccountKey, thirdID)

        _ = try await service.removeAccount(accountKey: thirdID, expectedActive: true)
        XCTAssertNil(try fixture.config()["lastKnownAccountUuid"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.desktop.appendingPathComponent("Cookies").path))
        registry = try await service.loadRegistry()
        XCTAssertEqual(registry.accounts.map(\.id), [secondID])
        XCTAssertNil(registry.activeAccountKey)
    }

    // 로그인은 끝났는데 조회가 계속 거부되면 제한 시간까지 기다리지 않고 원래 세션을 복구한 뒤 이유를 알린다.
    func testPersistentDenialEndsLoginAndRestoresSession() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID])
        fixture.runtime.accountOnFirstOpen = secondID
        fixture.runtime.cookieOnlyLogin = true
        AuthTestURLProtocol.reset(status: 403)
        defer { AuthTestURLProtocol.reset() }
        let service = fixture.service()
        do {
            _ = try await service.connectAccount()
            XCTFail("계속 거부된 조회를 로그인 성공으로 처리했습니다.")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .accessDenied(.profile))
        }
        XCTAssertEqual(AuthTestURLProtocol.requestCount(), 3)
        XCTAssertEqual(try fixture.config()["lastKnownAccountUuid"] as? String, firstID)
        XCTAssertEqual(try String(contentsOf: fixture.desktop.appendingPathComponent("Cookies"), encoding: .utf8), "cookies-first")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.storage.appendingPathComponent("recovery.json").path))
        let registry = try await service.loadRegistry()
        XCTAssertEqual(registry.accounts.map(\.id), [firstID])
    }

    // 쿠키 세션으로 조회할 때는 데스크톱이 마지막으로 연 조직의 사용량을 요청한다.
    func testWebLookupUsesOrganizationOpenedInDesktop() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        try fixture.setLive(firstID, cookies: "cookies-first")
        try fixture.saveRegistry([firstID])
        fixture.runtime.accountOnFirstOpen = secondID
        fixture.runtime.cookieOnlyLogin = true
        let service = fixture.service()
        _ = try await service.connectAccount()
        fixture.runtime.stop()
        try await service.switchAccount(accountKey: secondID)
        AuthTestURLProtocol.reset()
        defer { AuthTestURLProtocol.reset() }
        try await service.refreshAccounts(interactive: true)
        XCTAssertEqual(AuthTestURLProtocol.usagePaths().last, "/api/organizations/33333333-3333-4333-8333-333333333333/usage")
        try fixture.writeLog([(Int64(Date().timeIntervalSince1970) - 5, secondID, personalOrg)])
        try await service.refreshAccounts(interactive: true)
        XCTAssertEqual(AuthTestURLProtocol.usagePaths().last, "/api/organizations/\(personalOrg)/usage")
    }

    // 파일 오류는 경로 없이 도메인과 코드만 기록하고, 앱이 정의한 오류는 종류를 그대로 남긴다.
    func testLogDescriptionOmitsFilePaths() {
        let fileError = CocoaError(.fileReadNoSuchFile, userInfo: [
            NSFilePathErrorKey: "/Users/someone/Library/Application Support/Claude/Cookies"
        ])
        XCTAssertEqual(ClaudeAuthService.logDescription(fileError), "NSCocoaErrorDomain(260)")
        let denied = ClaudeAuthService.logDescription(ClaudeUsageError.accessDenied(.usage))
        XCTAssertTrue(denied.contains("accessDenied") && denied.contains("usage"))
        XCTAssertEqual(ClaudeAuthService.logDescription(ClaudeAuthError.snapshotNotFound), "snapshotNotFound")
    }

    // XCTUnwrap은 비동기 표현식을 받지 못하므로 목록을 먼저 읽은 뒤 첫 계정을 꺼낸다.
    private func firstAccount(_ service: ClaudeAuthService, importing: Bool = false) async throws -> CodexAccount {
        let registry = importing ? try await service.loadOrImportLocalRegistry() : try await service.loadRegistry()
        return try XCTUnwrap(registry.accounts.first)
    }

    @MainActor
    private final class Fixture {
        let root: URL
        let desktop: URL
        let storage: URL
        let runtime: FakeRuntime
        let session: URLSession

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("ClaudeAuthTests-\(UUID().uuidString)", isDirectory: true)
            desktop = root.appendingPathComponent("Claude", isDirectory: true)
            storage = root.appendingPathComponent("Saved", isDirectory: true)
            runtime = FakeRuntime(desktop: desktop)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AuthTestURLProtocol.self]
            session = URLSession(configuration: configuration)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func cleanup() {
            session.invalidateAndCancel()
            try? FileManager.default.removeItem(at: root)
        }

        // 계정 확인 도중 Claude가 다시 열린 상황은 복호화 시점에 실행 상태를 바꿔 만든다.
        var relaunchDuringVerification = false
        private let relaunched = RelaunchFlag()

        // keychainAvailable이 false면 키체인 승인 전의 자동 조회처럼 복호화를 거부한다.
        func service(keychainAvailable: Bool = true) -> ClaudeAuthService {
            let runtime = runtime
            let relaunched = relaunchDuringVerification ? relaunched : nil
            let app = ClaudeAuthService.Runtime(isRunning: { runtime.running || relaunched?.isSet == true },
                                                stop: { runtime.stop() }, open: { try runtime.open() })
            let client = ClaudeUsageClient(session: session, decrypt: { id, _ in
                relaunched?.set()
                guard keychainAvailable else { throw ClaudeUsageError.keychainUnavailable }
                return try JSONSerialization.data(withJSONObject: ["acct:\(id)|desktop:user:profile": [
                    "token": id, "expiresAt": 4_102_444_800_000
                ] as [String: Any]])
            })
            return ClaudeAuthService(dataDirectory: desktop, logDirectory: root.appendingPathComponent("Logs", isDirectory: true),
                                     storageDirectory: storage, runtime: app, client: client,
                                     webClient: ClaudeWebClient(session: session),
                                     loginTimeout: .seconds(10), pollInterval: .milliseconds(10))
        }

        func setLive(_ id: String, cookies: String) throws {
            try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["lastKnownAccountUuid": id, "oauth:tokenCacheV2": id,
                                                       "oauth:tokenCache": "legacy-\(id)", "locale": "ko-KR", "zoom": 1.25])
                .write(to: desktop.appendingPathComponent("config.json"))
            try Data(cookies.utf8).write(to: desktop.appendingPathComponent("Cookies"))
        }

        // 데스크톱이 남기는 사용률 표본·세션 폴더·로그를 같은 형식의 가짜 파일로 만든다.
        func writeHistory(_ samples: [(Int64, String, [String: Double])]) throws {
            let body: [String: Any] = ["version": 2, "samples": samples.map { ["t": $0.0 * 1_000, "org": $0.1, "u": $0.2] }]
            try JSONSerialization.data(withJSONObject: body).write(to: desktop.appendingPathComponent("plan-usage-history.json"))
        }

        func linkOrganization(_ organization: String, to account: String) throws {
            try FileManager.default.createDirectory(
                at: desktop.appendingPathComponent("claude-code-sessions/\(account)/\(organization)", isDirectory: true),
                withIntermediateDirectories: true)
        }

        func writeLog(_ loads: [(Int64, String, String)]) throws {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
            let lines = loads.map {
                "\(formatter.string(from: Date(timeIntervalSince1970: Double($0.0)))) [info] [LocalSessionManager] Initialization succeeded — accountId=\($0.1), orgId=\($0.2), existingSessions=0"
            }
            let directory = root.appendingPathComponent("Logs", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data(lines.joined(separator: "\n").utf8).write(to: directory.appendingPathComponent("main.log"))
        }

        func config() throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(contentsOf: desktop.appendingPathComponent("config.json"))) as! [String: Any]
        }

        func saveRegistry(_ ids: [String]) throws {
            try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["version": 1, "accounts": ids.map { ["id": $0, "email": "\($0)@example.com"] }])
                .write(to: storage.appendingPathComponent("registry.json"))
        }

        func snapshot(_ id: String, cookies: String) throws -> [String: Any] {
            let values = ["lastKnownAccountUuid": id, "oauth:tokenCacheV2": id, "oauth:tokenCache": "legacy-\(id)"]
            let auth = try values.mapValues { try JSONEncoder().encode($0).base64EncodedString() }
            return ["auth": auth, "cookies": ["Cookies": Data(cookies.utf8).base64EncodedString()]]
        }

        func snapshotURL(_ id: String) -> URL {
            storage.appendingPathComponent("accounts/\(id).json")
        }

        func saveSnapshot(_ id: String, cookies: String, authID: String? = nil) throws {
            try FileManager.default.createDirectory(at: storage.appendingPathComponent("accounts"), withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: snapshot(authID ?? id, cookies: cookies)).write(to: snapshotURL(id))
        }
    }

    // 테스트 런타임은 가짜 폴더만 변경하고 설치된 앱이나 사용자 인증에 접근하지 않는다.
    @MainActor
    private final class FakeRuntime {
        let desktop: URL
        var running = false
        var stopCount = 0
        var openCount = 0
        var accountOnFirstOpen: String?
        var cookieOnlyLogin = false
        init(desktop: URL) { self.desktop = desktop }
        func stop() { stopCount += 1; running = false }
        func open() throws -> Bool {
            openCount += 1
            running = true
            if openCount == 1, let id = accountOnFirstOpen {
                let url = desktop.appendingPathComponent("config.json")
                var config = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
                config["lastKnownAccountUuid"] = id
                config["oauth:tokenCacheV2"] = cookieOnlyLogin ? nil : id
                if cookieOnlyLogin { config["oauth:tokenCache"] = nil }
                try JSONSerialization.data(withJSONObject: config).write(to: url)
                let cookies = desktop.appendingPathComponent("Cookies")
                if cookieOnlyLogin {
                    if FileManager.default.fileExists(atPath: cookies.path) {
                        try FileManager.default.removeItem(at: cookies)
                    }
                    var database: OpaquePointer?
                    guard sqlite3_open(cookies.path, &database) == SQLITE_OK else { throw ClaudeUsageError.invalidCredential }
                    defer { sqlite3_close(database) }
                    let sql = "CREATE TABLE meta(key TEXT,value INTEGER); INSERT INTO meta VALUES('version',23); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,expires_utc INTEGER,creation_utc INTEGER); INSERT INTO cookies VALUES('.claude.ai','sessionKey','\(id)',X'',0,1);"
                    guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw ClaudeUsageError.invalidCredential }
                } else {
                    try Data("new-account-cookies".utf8).write(to: cookies)
                }
            }
            return true
        }
    }
}

// 테스트 스레드와 네트워크 대역 스레드가 함께 읽는 실행 상태 표시다.
private final class RelaunchFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); defer { lock.unlock() }; value = true }
}

private final class AuthTestURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var status = 200
    nonisolated(unsafe) private static var delay: TimeInterval = 0
    nonisolated(unsafe) private static var organizationType = "claude_pro"
    nonisolated(unsafe) private static var inFlight = 0
    nonisolated(unsafe) private static var peak = 0
    nonisolated(unsafe) private static var organizationUsagePaths: [String] = []
    nonisolated(unsafe) private static var usage: [String: Any] = defaultUsage
    nonisolated(unsafe) private static let defaultUsage: [String: Any] = [
        "five_hour": ["utilization": 25, "resets_at": "2099-01-01T00:00:00Z"],
        "seven_day": ["utilization": 60, "resets_at": "2099-01-05T00:00:00Z"]
    ]

    // 요청 수·상태 코드·사용량 응답만 테스트별로 바꾸며 실제 네트워크는 쓰지 않는다.
    static func reset(usage: [String: Any]? = nil, status: Int = 200, delay: TimeInterval = 0,
                      organizationType: String = "claude_pro") {
        lock.lock(); defer { lock.unlock() }
        count = 0
        self.organizationType = organizationType
        peak = 0
        self.delay = delay
        organizationUsagePaths = []
        self.status = status
        self.usage = usage ?? defaultUsage
    }
    static func requestCount() -> Int { lock.lock(); defer { lock.unlock() }; return count }
    static func usagePaths() -> [String] { lock.lock(); defer { lock.unlock() }; return organizationUsagePaths }
    // 응답을 늦춘 동안 겹쳐 있던 요청 수의 최댓값이다.
    static func peakRequests() -> Int { lock.lock(); defer { lock.unlock() }; return peak }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.count += 1
        let usage = Self.usage
        let status = Self.status
        let delay = Self.delay
        let organizationType = Self.organizationType
        Self.inFlight += 1
        Self.peak = max(Self.peak, Self.inFlight)
        if let path = request.url?.path, path.hasPrefix("/api/organizations/") { Self.organizationUsagePaths.append(path) }
        Self.lock.unlock()
        let id = request.value(forHTTPHeaderField: "Cookie").map { String($0.dropFirst("sessionKey=".count)) }
            ?? String((request.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst(7))
        // 계정이 채팅 조직 두 곳에 속한 경우를 기본 응답으로 둔다.
        let organization = "33333333-3333-4333-8333-333333333333"
        let secondOrganization = "55555555-5555-4555-8555-555555555555"
        let body: Any
        switch request.url?.path {
        case "/api/oauth/profile":
            body = ["account": ["uuid": id, "email": "\(id)@example.com"], "organization": ["organization_type": organizationType]]
        case "/api/account":
            body = ["uuid": id, "email_address": "\(id)@example.com",
                    "memberships": [["organization": ["uuid": organization, "rate_limit_tier": "claude_pro"]],
                                    ["organization": ["uuid": secondOrganization, "rate_limit_tier": "claude_pro"]]]]
        case "/api/organizations":
            body = [["uuid": organization, "capabilities": ["chat"], "rate_limit_tier": "claude_pro"],
                    ["uuid": secondOrganization, "capabilities": ["chat"], "rate_limit_tier": "claude_pro"]]
        default:
            body = usage
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
        let data = try! JSONSerialization.data(withJSONObject: status == 200 ? body : [:])
        let finish: @Sendable () -> Void = { [self] in
            Self.lock.lock()
            Self.inFlight -= 1
            Self.lock.unlock()
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
        // 지연을 준 테스트에서만 응답을 늦춰 요청이 겹치는지 관찰한다.
        if delay > 0 { DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: finish) } else { finish() }
    }
    override func stopLoading() {}
}
