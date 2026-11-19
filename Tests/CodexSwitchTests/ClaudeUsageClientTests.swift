import Foundation
import XCTest
@testable import CodexSwitch

@MainActor
final class ClaudeUsageClientTests: XCTestCase {
    // OpenSSL에서 생성한 고정 벡터로 PBKDF2·AES·패딩을 함께 검증한다.
    func testDecryptsDesktopV10CacheWithoutKeychain() throws {
        let encrypted = "djEwBdZ+8RrhpyYNk/sOpnJLYT8JslW9ihp43/Y1OfBInK7i5hx1E+0J1vqDPOKVT9L10B+flUxFOk4RIEZzoz0ch9w7wgvPqB7OQnSMWV/vVDoPfJzDrlz0b7uR4p+IDev/LpJhSSq9VwxWxEPtrR5rEQ=="
        let plain = try ClaudeCredentialCipher.decrypt(encrypted, password: Data("test-password".utf8))
        let expected = #"{"acct:test-account|client:org:api:user:profile":{"token":"test-token","expiresAt":4102444800000}}"#
        XCTAssertEqual(String(data: plain, encoding: .utf8), expected)
        let truncated = Data(Data(base64Encoded: encrypted)!.dropLast()).base64EncodedString()
        XCTAssertThrowsError(try ClaudeCredentialCipher.decrypt(truncated, password: Data("test-password".utf8)))
        XCTAssertThrowsError(try ClaudeCredentialCipher.decrypt(Data("v11bad".utf8).base64EncodedString(), password: Data()))
    }

    // 응답의 두 한도와 소수점 날짜를 읽고 없는 주간 한도를 만들어 내지 않는다.
    func testUsageWindowsAndInvalidResponses() throws {
        let response = #"{"five_hour":{"utilization":23.5,"resets_at":"2026-10-28T10:00:00.123456Z"},"seven_day":{"utilization":61,"resets_at":"2026-11-01T00:00:00Z"}}"#
        let usage = try ClaudeUsageClient.decodeUsage(Data(response.utf8), plan: "Max")
        XCTAssertEqual(usage.primary?.usedPercent, 23.5)
        XCTAssertEqual(usage.primary?.windowMinutes, 300)
        XCTAssertEqual(usage.secondary?.usedPercent, 61)
        XCTAssertEqual(usage.secondary?.windowMinutes, 10_080)
        XCTAssertEqual(usage.planType, "Max")
        XCTAssertEqual(usage.primary?.resetsAt, 1_793_181_600)
        let partial = try ClaudeUsageClient.decodeUsage(Data(#"{"five_hour":{"utilization":0,"resets_at":null},"seven_day":null}"#.utf8))
        XCTAssertNotNil(partial.primary)
        XCTAssertNil(partial.secondary)
        // 한도 키가 전혀 없거나 표시할 값 없이 잘못된 비율만 있으면 응답 오류다.
        for invalid in [#"{}"#, #"{"error":"x"}"#, #"{"five_hour":{"utilization":-1}}"#,
                        #"{"five_hour":{"utilization":-1},"seven_day":null}"#] {
            XCTAssertThrowsError(try ClaudeUsageClient.decodeUsage(Data(invalid.utf8))) {
                XCTAssertEqual($0 as? ClaudeUsageError, .invalidResponse)
            }
        }
        // 한도를 넘긴 비율은 0% 남음으로, 읽을 수 없는 초기화 시각은 사용률만 남겨 표시한다.
        let over = try ClaudeUsageClient.decodeUsage(Data(#"{"five_hour":{"utilization":101}}"#.utf8))
        XCTAssertEqual(over.primary?.usedPercent, 100)
        let badDate = try ClaudeUsageClient.decodeUsage(Data(#"{"five_hour":{"utilization":1,"resets_at":"invalid"}}"#.utf8))
        XCTAssertEqual(badDate.primary?.usedPercent, 1)
        XCTAssertNil(badDate.primary?.resetsAt)
    }

    // 한 기간의 빈 값·잘못된 값이 다른 기간을 숨기지 않고, 미제공과 실제 0%를 구분한다.
    func testWindowsDecodeIndependently() throws {
        func remaining(_ window: UsageWindow?) -> Int? { window.flatMap { UsageMeter(window: $0) }?.remainingPercent }
        for json in [#"{"five_hour":null,"seven_day":{"utilization":40}}"#,
                     #"{"five_hour":{"utilization":null},"seven_day":{"utilization":40}}"#,
                     #"{"five_hour":{"utilization":-3},"seven_day":{"utilization":40}}"#,
                     #"{"seven_day":{"utilization":40,"resets_at":null}}"#] {
            let usage = try ClaudeUsageClient.decodeUsage(Data(json.utf8))
            XCTAssertNil(usage.primary, json)
            XCTAssertEqual(remaining(usage.secondary), 60, json)
        }
        let fiveHourOnly = try ClaudeUsageClient.decodeUsage(Data(#"{"five_hour":{"utilization":12.4},"seven_day":{"utilization":null}}"#.utf8))
        XCTAssertEqual(remaining(fiveHourOnly.primary), 88)
        XCTAssertNil(fiveHourOnly.secondary)
        let zero = try ClaudeUsageClient.decodeUsage(Data(#"{"five_hour":{"utilization":0},"seven_day":null}"#.utf8))
        XCTAssertEqual(zero.primary?.usedPercent, 0)
        XCTAssertEqual(remaining(zero.primary), 100)
        // 두 기간 모두 미제공이면 오류가 아니라 값이 없는 응답으로 읽는다.
        let none = try ClaudeUsageClient.decodeUsage(Data(#"{"five_hour":null,"seven_day":null}"#.utf8))
        XCTAssertNil(none.primary)
        XCTAssertNil(none.secondary)
    }

    // 모델에만 걸린 주간 한도는 이름과 함께 따로 읽고, 전체 한도 항목이나 읽을 수 없는 항목은 넣지 않는다.
    func testModelScopedWeeklyLimitsAreReadFromLimits() throws {
        let response = #"""
        {"five_hour":{"utilization":0,"resets_at":null},
         "seven_day":{"utilization":6,"resets_at":"2026-11-24T14:00:00.328042+00:00"},
         "limits":[
          {"group":"session","kind":"session","percent":0,"resets_at":null,"scope":null},
          {"group":"weekly","kind":"weekly_all","percent":6,"resets_at":"2026-11-24T14:00:00.328042+00:00","scope":null},
          {"group":"weekly","kind":"weekly_scoped","percent":11,"resets_at":"2026-11-24T14:00:00.328161+00:00",
           "scope":{"model":{"display_name":"Fable","id":null},"surface":null}},
          {"group":"weekly","kind":"weekly_scoped","percent":140,"resets_at":null,"scope":{"model":{"display_name":"Opus"}}},
          {"group":"weekly","kind":"weekly_scoped","percent":null,"scope":{"model":{"display_name":"Sonnet"}}},
          {"group":"weekly","kind":"weekly_scoped","percent":-1,"scope":{"model":{"display_name":"Haiku"}}},
          {"group":"weekly","kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":" "}}},
          {"group":"weekly","kind":"weekly_scoped","percent":5,"scope":{"model":null,"surface":"cowork"}}
         ]}
        """#
        let usage = try ClaudeUsageClient.decodeUsage(Data(response.utf8))
        XCTAssertEqual(usage.secondary?.usedPercent, 6)
        XCTAssertEqual(usage.scoped?.map(\.scope), ["Fable", "Opus"])
        XCTAssertEqual(usage.scoped?.map(\.usedPercent), [11, 100])
        XCTAssertEqual(usage.scoped?.map(\.windowMinutes), [10_080, 10_080])
        XCTAssertEqual(usage.scoped?.first?.resetsAt, 1_795_528_800)
        XCTAssertNil(usage.scoped?.last?.resetsAt)
        let meter = try XCTUnwrap(usage.scoped?.first.flatMap {
            UsageMeter(window: $0, now: Date(timeIntervalSince1970: 1_795_000_000))
        })
        XCTAssertEqual(meter.remainingPercent, 89)
        XCTAssertNotEqual(meter.id, usage.secondary.flatMap { UsageMeter(window: $0) }?.id)
        // 모델별 한도가 없는 응답과 형식이 다른 limits는 기존 두 기간만 읽는다.
        for json in [#"{"five_hour":{"utilization":1},"limits":[]}"#, #"{"five_hour":{"utilization":1},"limits":"none"}"#,
                     #"{"five_hour":{"utilization":1}}"#] {
            let plain = try ClaudeUsageClient.decodeUsage(Data(json.utf8))
            XCTAssertNil(plain.scoped, json)
            XCTAssertEqual(plain.primary?.usedPercent, 1, json)
        }
        // 저장한 값을 다시 읽어도 모델 이름이 유지되고, 이 항목이 없는 기존 저장값도 그대로 읽힌다.
        let restored = try JSONDecoder().decode(UsageSnapshot.self, from: JSONEncoder().encode(usage))
        XCTAssertEqual(restored.scoped?.map(\.scope), ["Fable", "Opus"])
        let legacy = try JSONDecoder().decode(UsageSnapshot.self, from: Data(
            #"{"primary":{"used_percent":7,"window_minutes":300,"resets_at":null},"secondary":null,"plan_type":"pro"}"#.utf8))
        XCTAssertNil(legacy.scoped)
        XCTAssertNil(legacy.primary?.scope)
    }

    // 현재 계정의 프로필 범위 토큰만 사용하고, 응답 UUID도 다시 비교한다.
    func testRequestsUseCorrectAccountAndVerifyServerIdentity() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        let client = makeClient(session: session, token: "test-token")
        let profile = try await client.profile(encryptedCache: "ignored", expectedAccountID: "test-account")
        XCTAssertEqual(profile.accountID, "test-account")
        XCTAssertEqual(profile.email, "test@example.com")
        XCTAssertEqual(profile.plan, "Max")
        let combined = try await client.profileAndUsage(encryptedCache: "ignored", expectedAccountID: "test-account")
        XCTAssertEqual(combined.profile, profile)
        XCTAssertEqual(combined.usage.primary?.usedPercent, 20)
        XCTAssertEqual(combined.usage.secondary?.usedPercent, 40)
        let other = makeClient(session: session, token: "bad-owner-token")
        do {
            _ = try await other.usage(encryptedCache: "ignored", expectedAccountID: "test-account")
            XCTFail("다른 계정의 사용량을 허용했습니다.")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .accountMismatch)
        }
    }

    // 다른 계정, 만료 토큰, 프로필 권한이 없는 토큰은 네트워크 요청 전에 거부한다.
    func testRejectsExpiredOrUnrelatedCacheEntries() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        for (index, entries) in [
            ["acct:another|client:user:profile": ["token": "test-token", "expiresAt": 4_102_444_800_000] as [String: Any]],
            ["acct:test-account|client:user:profile": ["token": "test-token", "expiresAt": 1] as [String: Any]],
            ["acct:test-account|client:user:inference": ["token": "test-token", "expiresAt": 4_102_444_800_000] as [String: Any]],
            ["acct:test-account|client:user:profile": ["token": "invalid\nheader", "expiresAt": 4_102_444_800_000] as [String: Any]]
        ].enumerated() {
            let data = try JSONSerialization.data(withJSONObject: entries)
            let client = ClaudeUsageClient(session: session, decrypt: { _, _ in data })
            do {
                _ = try await client.profile(encryptedCache: "ignored", expectedAccountID: "test-account")
                XCTFail("사용할 수 없는 토큰을 허용했습니다.")
            } catch {
                XCTAssertEqual(error as? ClaudeUsageError, index == 1 ? .tokenExpired : .invalidCredential)
            }
        }
    }

    // 401과 429를 사용량 0으로 오인하지 않고 재조회 시각을 호출자에게 넘긴다.
    func testHTTPFailureAndRetryAfterArePreserved() async throws {
        let session = makeSession()
        defer { session.invalidateAndCancel() }
        do {
            _ = try await makeClient(session: session, token: "401-token").profile(
                encryptedCache: "ignored", expectedAccountID: "test-account")
            XCTFail("만료된 로그인을 성공으로 처리했습니다.")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .signedOut)
        }
        // 접근 거부는 로그아웃으로 바꾸지 않고 실패한 단계를 보존한다.
        do {
            _ = try await makeClient(session: session, token: "403-token").profile(
                encryptedCache: "ignored", expectedAccountID: "test-account")
            XCTFail("거부된 조회를 성공으로 처리했습니다.")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .accessDenied(.profile))
        }
        do {
            _ = try await makeClient(session: session, token: "usage-403-token").usage(
                encryptedCache: "ignored", expectedAccountID: "test-account")
            XCTFail("거부된 사용량 조회를 성공으로 처리했습니다.")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .accessDenied(.usage))
        }
        do {
            _ = try await makeClient(session: session, token: "offline-token").profile(
                encryptedCache: "ignored", expectedAccountID: "test-account")
            XCTFail("연결 실패를 성공으로 처리했습니다.")
        } catch {
            XCTAssertEqual(error as? ClaudeUsageError, .connectionFailed)
        }
        let before = Date()
        do {
            _ = try await makeClient(session: session, token: "429-token").profile(
                encryptedCache: "ignored", expectedAccountID: "test-account")
            XCTFail("조회 제한을 성공으로 처리했습니다.")
        } catch let ClaudeUsageError.rateLimited(retry) {
            XCTAssertGreaterThanOrEqual(retry.timeIntervalSince(before), 119)
            XCTAssertLessThan(retry.timeIntervalSince(before), 125)
        }
    }

    // 기본 세션은 인증 응답을 보관하지 않고 다른 주소로의 이동도 거부한다.
    func testDefaultSessionDoesNotPersistOrRedirectCredentials() async throws {
        let session = ClaudeUsageClient.ephemeralSession()
        defer { session.invalidateAndCancel() }
        XCTAssertNil(session.configuration.urlCache)
        XCTAssertNil(session.configuration.httpCookieStorage)
        XCTAssertNil(session.configuration.urlCredentialStorage)
        let delegate = try XCTUnwrap(session.delegate as? URLSessionTaskDelegate)
        let original = URL(string: "https://api.anthropic.com/api/oauth/usage")!
        let task = session.dataTask(with: original)
        let response = HTTPURLResponse(url: original, statusCode: 302, httpVersion: nil, headerFields: nil)!
        await withCheckedContinuation { continuation in
            delegate.urlSession?(session, task: task, willPerformHTTPRedirection: response,
                                 newRequest: URLRequest(url: URL(string: "https://example.invalid/")!),
                                 completionHandler: { request in
                XCTAssertNil(request)
                continuation.resume()
            })
        }
    }

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ClaudeUsageProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeClient(session: URLSession, token: String) -> ClaudeUsageClient {
        let cache = #"{"acct:other|client:user:profile":{"token":"never-use-other","expiresAt":4102444900000},"acct:test-account|client:user:profile":{"token":"TOKEN","expiresAt":4102444800000}}"#
            .replacingOccurrences(of: "TOKEN", with: token)
        return ClaudeUsageClient(session: session, decrypt: { _, _ in Data(cache.utf8) })
    }
}

// 고정 응답만 반환하므로 테스트 간 전역 핸들러나 실제 네트워크가 필요하지 않다.
private final class ClaudeUsageProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard request.url?.host == "api.anthropic.com",
              request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20",
              request.httpShouldHandleCookies == false else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let token = request.value(forHTTPHeaderField: "Authorization") ?? ""
        let status: Int
        let body: String
        if token == "Bearer 401-token" {
            status = 401
            body = "{}"
        } else if token == "Bearer 429-token" {
            status = 429
            body = "{}"
        } else if token == "Bearer offline-token" {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        } else if token == "Bearer 403-token"
                    || (token == "Bearer usage-403-token" && request.url?.path == "/api/oauth/usage") {
            status = 403
            body = "{}"
        } else if request.url?.path == "/api/oauth/profile" {
            status = 200
            let id = token == "Bearer bad-owner-token" ? "other-account" : "test-account"
            body = #"{"account":{"uuid":"ID","email":"test@example.com","display_name":"Test","has_claude_pro":true},"organization":{"organization_type":"claude_max"}}"#
                .replacingOccurrences(of: "ID", with: id)
        } else {
            status = 200
            body = #"{"five_hour":{"utilization":20},"seven_day":{"utilization":40}}"#
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Retry-After": "120"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
