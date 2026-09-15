import Foundation
import XCTest
@testable import CodexSwitch

final class LocalUsageReaderTests: XCTestCase {
    // 명시적으로 요청한 경우 현재 계정 표시값을 읽어 확인하며 원본은 변경하지 않는다.
    func testLiveLocalReadWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CODEXSWITCH_VERIFY_LOCAL_USAGE"] == "1" else {
            throw XCTSkip("실제 로컬 기록 검증은 명시적으로 요청한 경우에만 실행")
        }
        let service = CodexAuthService()
        let registry = try await service.loadRegistry()
        let active = try XCTUnwrap(registry.accounts.first { $0.accountKey == registry.activeAccountKey })
        XCTAssertFalse(active.usageMeters.isEmpty)
        print("Verified local windows: \(active.usageMeters.map(\.windowMinutes)); remaining: \(active.usageMeters.map(\.remainingPercent))")
    }

    // 더 최신인 Spark 기록이 같은 파일과 다른 파일에 있어도 일반 Codex 주간 값을 보존한다.
    func testSparkDoesNotReplaceCodexUsage() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let main = root.appendingPathComponent("rollout-main.jsonl")
        try Data((event(at: 100, limitID: "codex", weekly: true)
                  + event(at: 200, limitID: "codex_bengalfox", weekly: false)).utf8).write(to: main)
        try Data(event(at: 300, limitID: "other", weekly: false).utf8)
            .write(to: root.appendingPathComponent("rollout-other.jsonl"))
        var reader = LocalUsageReader()
        let reading = try XCTUnwrap(reader.latest(in: root, since: .distantPast))
        XCTAssertEqual(reading.timestamp.timeIntervalSince1970, 100)
        XCTAssertEqual(reading.usage.primary?.windowMinutes, 10_080)
        XCTAssertEqual(reading.usage.primary?.usedPercent, 15)
        XCTAssertNil(reading.usage.secondary)
        XCTAssertNil(reader.latest(in: root, since: Date(timeIntervalSince1970: 101)))
    }

    // 나중에 5h가 추가되거나 다시 없어져도 최신 일반 Codex 기록의 창 구성을 따른다.
    func testWindowChangesAndCacheRefresh() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-main.jsonl")
        var text = event(at: 100, limitID: "codex", weekly: true)
        try Data(text.utf8).write(to: file)
        var reader = LocalUsageReader()
        XCTAssertNil(reader.latest(in: root, since: .distantPast)?.usage.secondary)
        text += event(at: 200, limitID: "codex", weekly: false)
        try Data(text.utf8).write(to: file)
        let dual = try XCTUnwrap(reader.latest(in: root, since: .distantPast))
        XCTAssertEqual(dual.usage.primary?.windowMinutes, 300)
        XCTAssertEqual(dual.usage.secondary?.windowMinutes, 10_080)
        text += event(at: 300, limitID: "codex", weekly: true)
        try Data(text.utf8).write(to: file)
        let weekly = try XCTUnwrap(reader.latest(in: root, since: .distantPast))
        XCTAssertEqual(weekly.usage.primary?.windowMinutes, 10_080)
        XCTAssertNil(weekly.usage.secondary)
    }

    // 레거시 로그·큰 줄·손상된 줄을 처리하되 별도 모델만 있으면 결과를 만들지 않는다.
    func testLegacyAndIncompleteLines() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-main.jsonl")
        let legacy = event(at: 100, limitID: "codex", weekly: true)
            .replacingOccurrences(of: "\"limit_id\":\"codex\",", with: "")
        let content = String(repeating: "x", count: 150_000) + "\n" + legacy + "{\"timestamp\":"
        try Data(content.utf8).write(to: file)
        var reader = LocalUsageReader()
        XCTAssertEqual(reader.latest(in: root, since: .distantPast)?.usage.primary?.usedPercent, 15)
        try Data(event(at: 200, limitID: "codex_bengalfox", weekly: false).utf8).write(to: file)
        XCTAssertNil(reader.latest(in: root, since: .distantPast))
    }

    // 역순 조회에서도 청크 경계를 넘는 정상 JSON과 후행 대화 본문을 처리한다.
    func testUsageAcrossBackwardReadBoundaries() throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("rollout-main.jsonl")
        let largeEvent = event(at: 200, limitID: "codex", weekly: true)
            .replacingOccurrences(of: "\"limit_id\":", with: "\"padding\":\"\(String(repeating: "x", count: 90_000))\",\"limit_id\":")
        let content = event(at: 100, limitID: "codex", weekly: false) + largeEvent
            + String(repeating: "x", count: 150_000) + "\n{\"timestamp\":"
        try Data(content.utf8).write(to: file)
        var reader = LocalUsageReader()
        let reading = try XCTUnwrap(reader.latest(in: root, since: .distantPast))
        XCTAssertEqual(reading.timestamp.timeIntervalSince1970, 200)
        XCTAssertEqual(reading.usage.primary?.windowMinutes, 10_080)
        XCTAssertNil(reading.usage.secondary)
    }

    // 모델 정보 없는 registry 캐시를 재사용하지 않고 로컬 원본으로 표시값을 교체한다.
    func testServiceIgnoresContaminatedRegistryCache() async throws {
        let root = try fixtureDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let accounts = root.appendingPathComponent("accounts")
        let sessions = root.appendingPathComponent("sessions")
        for folder in [accounts, sessions] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let registryURL = accounts.appendingPathComponent("registry.json")
        let json = #"{"schema_version":3,"active_account_key":"test","active_account_activated_at_ms":90000,"accounts":[{"account_key":"test","email":"test@example.com","last_usage":{"primary":{"used_percent":0,"window_minutes":300},"secondary":{"used_percent":0,"window_minutes":10080}}}]}"#
        try Data(json.utf8).write(to: registryURL)
        let service = CodexAuthService(registryURL: registryURL, environment: [:])
        let missing = try await service.loadRegistry()
        XCTAssertNil(missing.accounts.first?.lastUsage)
        try Data(event(at: 100, limitID: "codex", weekly: true).utf8)
            .write(to: sessions.appendingPathComponent("rollout-main.jsonl"))
        let result = try await service.loadRegistry()
        XCTAssertEqual(result.accounts.first?.usageMeters.map(\.windowMinutes), [10_080])
        XCTAssertEqual(result.accounts.first?.usageMeters.first?.remainingPercent, 85)
        XCTAssertEqual(try Data(contentsOf: registryURL), Data(json.utf8))
    }

    private func fixtureDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LocalUsage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func event(at timestamp: TimeInterval, limitID: String, weekly: Bool) -> String {
        let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: timestamp))
        let windows = weekly
            ? #""primary":{"used_percent":15,"window_minutes":10080},"secondary":null"#
            : #""primary":{"used_percent":0,"window_minutes":300},"secondary":{"used_percent":0,"window_minutes":10080}"#
        return "{\"timestamp\":\"\(date)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"rate_limits\":{\"limit_id\":\"\(limitID)\",\(windows)}}}\n"
    }
}
