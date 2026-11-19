import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import CodexSwitch

@MainActor
final class ClaudeWebClientTests: XCTestCase {
    // Code OAuth가 없어도 데스크톱 웹 세션으로 계정과 두 사용량 창을 읽는다.
    func testCookieOnlyLoginAndUsageWithDomainBoundCiphertext() async throws {
        let fixture = try Fixture(version: 24)
        defer { fixture.cleanup() }
        try fixture.cookie(encrypted: Data("current".utf8))
        let before = try Data(contentsOf: fixture.database)
        let client = fixture.client { _, interaction in
            XCTAssertTrue(interaction)
            return Data(SHA256.hash(data: Data(".claude.ai".utf8))) + Data("sk-ant-test".utf8)
        }
        let result = try await client.profileAndUsage(cookieDatabase: fixture.database,
                                                     expectedAccountID: WebTestData.account,
                                                     allowKeychainPrompt: true)
        XCTAssertEqual(result.profile.accountID, WebTestData.account)
        XCTAssertEqual(result.profile.email, "claude@example.com")
        XCTAssertEqual(result.profile.plan, "Pro")
        XCTAssertEqual(result.usage.primary?.usedPercent, 25)
        XCTAssertEqual(result.usage.secondary?.usedPercent, 60)
        XCTAssertEqual(try Data(contentsOf: fixture.database), before)
        let requests = ClaudeWebTestProtocol.requests()
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/account", "/api/organizations", "/api/organizations/\(WebTestData.organization)/usage"])
        for request in requests {
            XCTAssertEqual(request.url?.host, "claude.ai")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cookie"), "sessionKey=sk-ant-test")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        }
    }

    // 오래된 쿠키와 이름만 비슷한 다른 호스트는 키체인 접근 전에 제외한다.
    func testSelectsOnlyUnexpiredExactDomainCookie() async throws {
        let fixture = try Fixture(version: 23)
        defer { fixture.cleanup() }
        let current = Data("current".utf8)
        try fixture.cookie(host: ".claude.ai", encrypted: current, created: 1)
        try fixture.cookie(host: ".claude.ai", encrypted: Data("expired".utf8), expires: 1, created: 3)
        try fixture.cookie(host: ".fake.claude.ai", encrypted: Data("other-domain".utf8), created: 4)
        let client = fixture.client { encoded, interaction in
            XCTAssertEqual(Data(base64Encoded: encoded), current)
            XCTAssertFalse(interaction)
            return Data("sk-ant-test".utf8)
        }
        let profile = try await client.profile(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account)
        XCTAssertEqual(profile.email, "claude@example.com")
    }

    // Chromium 24 이상은 암호문에 결합된 호스트 해시가 다르면 거부한다.
    func testRejectsWrongDomainHashBeforeSendingCookie() async throws {
        let fixture = try Fixture(version: 24)
        defer { fixture.cleanup() }
        try fixture.cookie(encrypted: Data("current".utf8))
        let client = fixture.client { _, _ in
            Data(SHA256.hash(data: Data("other.example".utf8))) + Data("sk-ant-test".utf8)
        }
        do {
            _ = try await client.profile(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account)
            XCTFail("다른 도메인의 쿠키를 허용했습니다.")
        } catch ClaudeUsageError.invalidCredential {}
        XCTAssertTrue(ClaudeWebTestProtocol.requests().isEmpty)
    }

    // 서버 계정이 다르면 조직과 사용량 조회를 시작하지 않는다.
    func testRejectsDifferentAccountBeforeUsageRequest() async throws {
        let fixture = try Fixture(version: 23)
        defer { fixture.cleanup() }
        try fixture.cookie(plain: "sk-ant-test")
        ClaudeWebTestProtocol.configure { _ in
            (200, [:], try! JSONSerialization.data(withJSONObject: ["uuid": WebTestData.otherAccount, "email_address": "other@example.com"]))
        }
        do {
            _ = try await fixture.client().profileAndUsage(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account)
            XCTFail("다른 계정의 사용량을 허용했습니다.")
        } catch ClaudeUsageError.accountMismatch {}
        XCTAssertEqual(ClaudeWebTestProtocol.requests().count, 1)
    }

    // 만료된 로그인은 네트워크로 보내지 않고 서버 제한의 재시도 시각은 유지한다.
    func testExpiryAndHTTPFailures() async throws {
        let fixture = try Fixture(version: 23)
        defer { fixture.cleanup() }
        try fixture.cookie(plain: "sk-ant-expired", expires: 1)
        do {
            _ = try await fixture.client().profile(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account)
            XCTFail("만료 쿠키를 전송했습니다.")
        } catch ClaudeUsageError.signedOut {}
        XCTAssertTrue(ClaudeWebTestProtocol.requests().isEmpty)
        try fixture.cookie(plain: "sk-ant-test", created: 2)
        ClaudeWebTestProtocol.configure { _ in (429, ["Retry-After": "90"], Data()) }
        do {
            _ = try await fixture.client().profile(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account)
            XCTFail("서버 요청 제한을 성공 처리했습니다.")
        } catch ClaudeUsageError.rateLimited(let until) {
            XCTAssertGreaterThan(until.timeIntervalSinceNow, 85)
        }
        ClaudeWebTestProtocol.configure { _ in (403, [:], Data()) }
        do {
            _ = try await fixture.client().profile(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account)
            XCTFail("거부된 세션을 허용했습니다.")
        } catch ClaudeUsageError.accessDenied(.profile) {}
        // 사용량 단계에서만 거부되면 그 단계가 오류에 남아 재로그인 안내와 구분된다.
        ClaudeWebTestProtocol.configure { request in
            let path = request.url!.path
            if path.hasSuffix("/usage") { return (403, [:], Data()) }
            let body: Any = path == "/api/account"
                ? ["uuid": WebTestData.account, "email_address": "claude@example.com"]
                : [["uuid": WebTestData.organization, "capabilities": ["chat"]]]
            return (200, [:], try! JSONSerialization.data(withJSONObject: body))
        }
        do {
            _ = try await fixture.client().profileAndUsage(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account)
            XCTFail("거부된 사용량 조회를 허용했습니다.")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .accessDenied(.usage))
        }
        ClaudeWebTestProtocol.configure { _ in (401, [:], Data()) }
        do {
            _ = try await fixture.client().profile(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account)
            XCTFail("로그아웃된 세션을 허용했습니다.")
        } catch ClaudeUsageError.signedOut {}
    }

    // 채팅 조직이 여러 개면 데스크톱이 열어 둔 조직을 고르고, 서버 목록에 없으면 기본 선택으로 돌아간다.
    func testPrefersDesktopOrganizationWhenListed() async throws {
        let fixture = try Fixture(version: 23)
        defer { fixture.cleanup() }
        try fixture.cookie(plain: "sk-ant-test")
        let respond: @Sendable (URLRequest) -> (Int, [String: String], Data) = { request in
            let organizations = [WebTestData.organization, WebTestData.apiOrganization]
            let body: Any
            switch request.url!.path {
            case "/api/account":
                body = ["uuid": WebTestData.account, "email_address": "claude@example.com",
                        "memberships": organizations.map { ["organization": ["uuid": $0, "rate_limit_tier": "claude_pro"]] }]
            case "/api/organizations":
                body = organizations.map { ["uuid": $0, "capabilities": ["chat"], "rate_limit_tier": "claude_pro"] }
            default:
                body = ["five_hour": ["utilization": 25], "seven_day": ["utilization": 60]]
            }
            return (200, [:], try! JSONSerialization.data(withJSONObject: body))
        }
        ClaudeWebTestProtocol.configure(respond)
        _ = try await fixture.client().profileAndUsage(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account,
                                                       preferredOrganizationID: WebTestData.apiOrganization.uppercased())
        XCTAssertEqual(ClaudeWebTestProtocol.requests().last?.url?.path, "/api/organizations/\(WebTestData.apiOrganization)/usage")
        ClaudeWebTestProtocol.configure(respond)
        _ = try await fixture.client().profileAndUsage(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account,
                                                       preferredOrganizationID: WebTestData.otherAccount)
        XCTAssertEqual(ClaudeWebTestProtocol.requests().last?.url?.path, "/api/organizations/\(WebTestData.organization)/usage")
    }

    // HTTP 헤더 구분 문자는 로컬 쿠키 DB에 있어도 전송하지 않는다.
    func testRejectsCookieHeaderInjection() async throws {
        let fixture = try Fixture(version: 23)
        defer { fixture.cleanup() }
        try fixture.cookie(plain: "sk-ant-test;another=value")
        do {
            _ = try await fixture.client().profile(cookieDatabase: fixture.database, expectedAccountID: WebTestData.account)
            XCTFail("헤더 구분 문자를 허용했습니다.")
        } catch ClaudeUsageError.invalidCredential {}
        XCTAssertTrue(ClaudeWebTestProtocol.requests().isEmpty)
    }

    private final class Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ClaudeWebTests-\(UUID().uuidString)")
        var database: URL { root.appendingPathComponent("Cookies") }
        let session: URLSession

        init(version: Int) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ClaudeWebTestProtocol.self]
            session = URLSession(configuration: configuration)
            ClaudeWebTestProtocol.configure { request in
                let body: Any
                switch request.url!.path {
                case "/api/account":
                    body = ["uuid": WebTestData.account, "email_address": "claude@example.com", "full_name": "Claude Test",
                            "memberships": [["organization": ["uuid": WebTestData.organization, "rate_limit_tier": "claude_pro"]]]]
                case "/api/organizations":
                    body = [["uuid": WebTestData.apiOrganization, "capabilities": ["api"]],
                            ["uuid": WebTestData.organization, "capabilities": ["chat"], "rate_limit_tier": "claude_pro"]]
                default:
                    body = ["five_hour": ["utilization": 25, "resets_at": "2030-01-01T00:00:00Z"],
                            "seven_day": ["utilization": 60, "resets_at": "2030-01-07T00:00:00.000Z"]]
                }
                return (200, [:], try! JSONSerialization.data(withJSONObject: body))
            }
            var handle: OpaquePointer?
            guard sqlite3_open(database.path, &handle) == SQLITE_OK else { throw ClaudeUsageError.invalidCredential }
            defer { sqlite3_close(handle) }
            let sql = "CREATE TABLE meta(key TEXT, value INTEGER); INSERT INTO meta VALUES('version',\(version)); CREATE TABLE cookies(host_key TEXT,name TEXT,value TEXT,encrypted_value BLOB,expires_utc INTEGER,creation_utc INTEGER);"
            guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw ClaudeUsageError.invalidCredential }
        }

        func client(decrypt: @escaping @Sendable (String, Bool) throws -> Data = { _, _ in throw ClaudeUsageError.invalidCredential }) -> ClaudeWebClient {
            ClaudeWebClient(session: session, decrypt: decrypt)
        }

        func cookie(host: String = ".claude.ai", plain: String = "", encrypted: Data = Data(), expires: Int64 = 0, created: Int64 = 1) throws {
            var handle: OpaquePointer?
            guard sqlite3_open(database.path, &handle) == SQLITE_OK else { throw ClaudeUsageError.invalidCredential }
            defer { sqlite3_close(handle) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(handle, "INSERT INTO cookies VALUES(?, 'sessionKey', ?, ?, ?, ?)", -1, &statement, nil) == SQLITE_OK else {
                throw ClaudeUsageError.invalidCredential
            }
            defer { sqlite3_finalize(statement) }
            let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
            sqlite3_bind_text(statement, 1, host, -1, transient)
            sqlite3_bind_text(statement, 2, plain, -1, transient)
            _ = encrypted.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(encrypted.count), transient) }
            sqlite3_bind_int64(statement, 4, expires)
            sqlite3_bind_int64(statement, 5, created)
            guard sqlite3_step(statement) == SQLITE_DONE else { throw ClaudeUsageError.invalidCredential }
        }

        func cleanup() { session.invalidateAndCancel(); try? FileManager.default.removeItem(at: root) }
    }
}

private enum WebTestData {
    static let account = "11111111-1111-4111-8111-111111111111"
    static let otherAccount = "22222222-2222-4222-8222-222222222222"
    static let organization = "33333333-3333-4333-8333-333333333333"
    static let apiOrganization = "44444444-4444-4444-8444-444444444444"
}

// 테스트의 쿠키와 응답은 모두 가짜 값이며 실제 네트워크 요청을 만들지 않는다.
private final class ClaudeWebTestProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> (Int, [String: String], Data))?
    nonisolated(unsafe) private static var recorded: [URLRequest] = []

    static func configure(_ value: @escaping @Sendable (URLRequest) -> (Int, [String: String], Data)) {
        lock.lock(); defer { lock.unlock() }
        handler = value
        recorded = []
    }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.recorded.append(request)
        let handler = Self.handler!
        Self.lock.unlock()
        let (status, headers, body) = handler(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
