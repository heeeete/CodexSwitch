import AppKit
import SwiftUI
import XCTest
@testable import CodexSwitch

final class ResetCreditTests: XCTestCase {
    // 실제 응답의 소수점 날짜를 읽고 사용·만료된 쿠폰을 제외해 만료일 순으로 정렬한다.
    func testExpirationOrderingAndFiltering() throws {
        let credits = try ResetCreditClient.decode(Data(Self.response.utf8))
        let now = ISO8601DateFormatter().date(from: "2026-09-14T00:00:00Z")!
        let available = ResetCredit.available(in: credits, at: now)
        XCTAssertEqual(available.map(\.id), ["soon", "later", "no-expiry"])
        XCTAssertEqual(available.first?.expiresAt?.timeIntervalSince1970 ?? 0, 1_789_949_495.816949, accuracy: 0.001)
        XCTAssertEqual(
            ResetCredit.available(in: credits, at: available[0].expiresAt!).map(\.id),
            ["later", "no-expiry"]
        )
        XCTAssertThrowsError(try ResetCreditClient.decode(Data(
            #"{"credits":[{"id":"broken","status":"available","reset_type":"codex_rate_limits","expires_at":"invalid"}]}"#.utf8
        )))
    }

    // 저장된 계정 스냅샷의 인증으로 GET을 만들고 다른 계정 인증은 거부한다.
    func testRequestUsesSelectedSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let registryURL = root.appendingPathComponent("registry.json")
        try Data(#"{"schema_version":3,"accounts":[{"account_key":"user::account","email":"test@example.com"}]}"#.utf8).write(to: registryURL)
        let snapshot = root.appendingPathComponent("dXNlcjo6YWNjb3VudA.auth.json")
        try Data(#"{"tokens":{"account_id":"account","access_token":"test-token"}}"#.utf8).write(to: snapshot)
        let service = CodexAuthService(registryURL: registryURL, environment: [:])
        let request = try await service.resetCreditRequest(accountKey: "user::account")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "account")
        try Data(#"{"tokens":{"account_id":"other","access_token":"test-token"}}"#.utf8).write(to: snapshot)
        do {
            _ = try await service.resetCreditRequest(accountKey: "user::account")
            XCTFail("다른 계정 인증을 허용했습니다.")
        } catch CodexAuthError.invalidLoginCredential { }
    }

    // 인증 실패를 빈 쿠폰 목록으로 오인하지 않는다.
    func testHTTPFailureIsNotEmptyCredits() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnauthorizedProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await ResetCreditClient.fetch(
                request: URLRequest(url: URL(string: "https://example.invalid/credits")!), session: session
            )
            XCTFail("HTTP 401을 성공으로 처리했습니다.")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
    }

    // 사용량 API가 꺼져 있어도 조회하고, 취소를 무시한 이전 계정 응답은 버린다.
    @MainActor
    func testLocalModeLoadsCreditsAndDiscardsPreviousAccountResult() async throws {
        let suite = "ResetCreditTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "autoRefreshEnabled")
        defaults.set(false, forKey: "directAPIRefreshEnabled")
        let loader = ControlledLoader()
        let store = AccountStore(userDefaults: defaults, resetCreditLoader: { key in
            await loader.load(key)
        })
        store.applyPreviewRegistry(try Self.registry(key: "first"))
        for _ in 0..<100 {
            if await loader.hasRequest("first") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        store.applyPreviewRegistry(try Self.registry(key: "second"))
        for _ in 0..<100 {
            if await loader.hasRequest("second") { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let newCredit = ResetCredit(id: "new", status: "available", resetType: "codex_rate_limits", expiresAt: nil)
        await loader.finish("second", credits: [newCredit])
        for _ in 0..<100 where store.resetCreditState == .loading {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.directAPIRefreshEnabled)
        XCTAssertEqual(store.resetCreditState, .loaded([newCredit]))
        await loader.finish("first", credits: [])
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(store.resetCreditState, .loaded([newCredit]))
    }

    // 쿠폰 목록이 372pt 메뉴에서 밝은 모드와 어두운 모드 모두 잘리지 않는지 확인한다.
    @MainActor
    func testCouponLayout() throws {
        let credits = try ResetCreditClient.decode(Data(Self.response.utf8)).map {
            ResetCredit(id: $0.id, status: $0.status, resetType: $0.resetType,
                        expiresAt: $0.expiresAt?.addingTimeInterval(10 * 365 * 86_400))
        }
        for scheme in [ColorScheme.light, .dark] {
            let view = NSHostingView(rootView: ResetCreditSection(state: .loaded(credits))
                .padding(16).frame(width: 372)
                .background(scheme == .dark ? Color.black : Color.white)
                .environment(\.colorScheme, scheme)
                .environment(\.locale, Locale(identifier: "ko_KR")))
            XCTAssertEqual(view.fittingSize.width, 372, accuracy: 1)
            XCTAssertLessThan(view.fittingSize.height, 170)
            if let root = ProcessInfo.processInfo.environment["CODEXSWITCH_COUPON_SNAPSHOT_ROOT"] {
                view.frame = NSRect(origin: .zero, size: view.fittingSize)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: URL(fileURLWithPath: "\(root)-\(scheme).png"))
            }
        }
    }

    // 명시적으로 켠 로컬 검증에서만 실제 저장된 현재 계정으로 읽기 요청을 보낸다.
    func testLiveReadWhenRequested() async throws {
        guard ProcessInfo.processInfo.environment["CODEXSWITCH_VERIFY_LIVE_COUPONS"] == "1" else {
            throw XCTSkip("실제 계정 API 검증은 명시적으로 요청한 경우에만 실행")
        }
        let service = CodexAuthService()
        let registry = try await service.loadRegistry()
        let key = try XCTUnwrap(registry.activeAccountKey)
        let credits = try await service.fetchResetCredits(accountKey: key)
        XCTAssertTrue(credits.allSatisfy { !$0.id.isEmpty })
        print("Live coupon GET succeeded: \(ResetCredit.available(in: credits, at: Date()).count) available")
    }

    private static func registry(key: String) throws -> AccountRegistry {
        try JSONDecoder().decode(AccountRegistry.self, from: JSONSerialization.data(withJSONObject: [
            "schema_version": 3, "active_account_key": key,
            "accounts": [["account_key": key, "email": "test@example.com"]]
        ]))
    }

    private static let response = #"""
    {"credits":[
      {"id":"later","status":"available","reset_type":"codex_rate_limits","expires_at":"2026-10-04T02:26:43Z"},
      {"id":"used","status":"redeemed","reset_type":"codex_rate_limits","expires_at":"2026-09-20T00:00:00Z"},
      {"id":"expired","status":"available","reset_type":"codex_rate_limits","expires_at":"2026-09-01T00:00:00Z"},
      {"id":"no-expiry","status":"available","reset_type":"codex_rate_limits","expires_at":null},
      {"id":"other","status":"available","reset_type":"other","expires_at":null},
      {"id":"soon","status":"available","reset_type":"codex_rate_limits","expires_at":"2026-09-21T00:11:35.816949Z"}
    ]}
    """#
}

// 네트워크 없이 실패 응답을 재현한다.
private final class UnauthorizedProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"credits":[]}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

// 이전 요청이 새 요청보다 늦게 끝나는 계정 전환 순서를 재현한다.
private actor ControlledLoader {
    private var requests: [String: CheckedContinuation<[ResetCredit], Never>] = [:]
    func load(_ key: String) async -> [ResetCredit] {
        await withCheckedContinuation { requests[key] = $0 }
    }
    func hasRequest(_ key: String) -> Bool { requests[key] != nil }
    func finish(_ key: String, credits: [ResetCredit]) {
        requests.removeValue(forKey: key)?.resume(returning: credits)
    }
}
