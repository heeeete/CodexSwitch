import CryptoKit
import Foundation
import SQLite3

// 데스크톱의 웹 로그인은 Code OAuth 발급과 독립적으로 확인한다.
struct ClaudeWebClient: Sendable {
    private let session: URLSession
    private let decrypt: @Sendable (String, Bool) throws -> Data

    init(
        session: URLSession = ClaudeUsageClient.ephemeralSession(),
        decrypt: @escaping @Sendable (String, Bool) throws -> Data = ClaudeCredentialCipher.decrypt
    ) {
        self.session = session
        self.decrypt = decrypt
    }

    func profile(
        cookieDatabase: URL,
        expectedAccountID: String,
        allowKeychainPrompt: Bool = false,
        expectedOrganizationID: String? = nil
    ) async throws -> ClaudeProfile {
        let cookie = try sessionKey(database: cookieDatabase, allowInteraction: allowKeychainPrompt)
        let account = try await account(cookie: cookie, expectedAccountID: expectedAccountID)
        let membership = account.memberships?.first {
            expectedOrganizationID == nil || $0.organization.uuid == expectedOrganizationID
        }
        return ClaudeProfile(accountID: expectedAccountID, email: account.email,
                             displayName: account.name, plan: membership?.organization.plan)
    }

    // 계정 확인과 조직 선택 후에만 사용량을 요청해 다른 계정의 수치를 섞지 않는다.
    func profileAndUsage(
        cookieDatabase: URL,
        expectedAccountID: String,
        allowKeychainPrompt: Bool = false,
        expectedOrganizationID: String? = nil,
        preferredOrganizationID: String? = nil
    ) async throws -> (profile: ClaudeProfile, usage: UsageSnapshot) {
        let cookie = try sessionKey(database: cookieDatabase, allowInteraction: allowKeychainPrompt)
        let account = try await account(cookie: cookie, expectedAccountID: expectedAccountID)
        let data = try await get("/api/organizations", cookie: cookie, stage: .organization)
        guard let organizations = try? JSONDecoder().decode([Organization].self, from: data),
              !organizations.isEmpty else { throw ClaudeUsageError.invalidResponse }
        let selected: Organization?
        if let expectedOrganizationID {
            selected = organizations.first { $0.uuid == expectedOrganizationID }
        } else {
            // 데스크톱이 열어 둔 조직이 서버 목록에 있으면 그 조직을 보고, 없으면 채팅 조직을 고른다.
            selected = organizations.first { $0.uuid.lowercased() == preferredOrganizationID?.lowercased() }
                ?? organizations.first { $0.capabilities?.contains("chat") == true }
                ?? organizations.first { $0.capabilities?.contains("api") != true }
                ?? organizations.first
        }
        guard let organization = selected, UUID(uuidString: organization.uuid) != nil else {
            throw ClaudeUsageError.invalidResponse
        }
        if let memberships = account.memberships, !memberships.isEmpty,
           !memberships.contains(where: { $0.organization.uuid == organization.uuid }) {
            throw ClaudeUsageError.accountMismatch
        }
        let member = account.memberships?.first { $0.organization.uuid == organization.uuid }
        let plan = member?.organization.plan ?? organization.plan
        let usageData = try await get("/api/organizations/\(organization.uuid)/usage", cookie: cookie, stage: .usage)
        let profile = ClaudeProfile(accountID: expectedAccountID, email: account.email,
                                    displayName: account.name, plan: plan)
        return (profile, try ClaudeUsageClient.decodeUsage(usageData, plan: plan))
    }

    // 실행 중인 Chromium DB도 읽기 전용 연결로 조회하고 원본 파일을 변경하지 않는다.
    private func sessionKey(database: URL, allowInteraction: Bool) throws -> String {
        var databaseHandle: OpaquePointer?
        guard sqlite3_open_v2(database.path, &databaseHandle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK,
              let databaseHandle else {
            if let databaseHandle { sqlite3_close(databaseHandle) }
            throw ClaudeUsageError.invalidCredential
        }
        defer { sqlite3_close(databaseHandle) }
        sqlite3_busy_timeout(databaseHandle, 500)
        var versionStatement: OpaquePointer?
        var version = 0
        if sqlite3_prepare_v2(databaseHandle, "SELECT value FROM meta WHERE key = 'version'", -1, &versionStatement, nil) == SQLITE_OK,
           sqlite3_step(versionStatement) == SQLITE_ROW {
            version = Int(sqlite3_column_int(versionStatement, 0))
        }
        sqlite3_finalize(versionStatement)
        var statement: OpaquePointer?
        let sql = "SELECT host_key, value, encrypted_value, expires_utc FROM cookies WHERE name = 'sessionKey' AND host_key IN ('.claude.ai', 'claude.ai') ORDER BY creation_utc DESC"
        guard sqlite3_prepare_v2(databaseHandle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ClaudeUsageError.invalidCredential
        }
        defer { sqlite3_finalize(statement) }
        let now = (Date().timeIntervalSince1970 + 11_644_473_600) * 1_000_000
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let hostBytes = sqlite3_column_text(statement, 0) else { continue }
            let host = String(cString: hostBytes)
            let expiry = sqlite3_column_double(statement, 3)
            guard expiry == 0 || expiry > now else { continue }
            let encryptedLength = Int(sqlite3_column_bytes(statement, 2))
            let value: Data
            if encryptedLength > 0, let encryptedBytes = sqlite3_column_blob(statement, 2) {
                let encrypted = Data(bytes: encryptedBytes, count: encryptedLength)
                var plaintext = try decrypt(encrypted.base64EncodedString(), allowInteraction)
                if version >= 24 {
                    let expectedHash = Data(SHA256.hash(data: Data(host.utf8)))
                    guard plaintext.count > expectedHash.count, plaintext.prefix(expectedHash.count) == expectedHash else {
                        throw ClaudeUsageError.invalidCredential
                    }
                    plaintext.removeFirst(expectedHash.count)
                }
                value = plaintext
            } else if let plainBytes = sqlite3_column_text(statement, 1) {
                value = Data(String(cString: plainBytes).utf8)
            } else { continue }
            guard let token = String(data: value, encoding: .utf8), !token.isEmpty,
                  token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) && !"\";,\\".unicodeScalars.contains($0) }) else {
                throw ClaudeUsageError.invalidCredential
            }
            return token
        }
        throw ClaudeUsageError.signedOut
    }

    private struct Organization: Decodable {
        let uuid: String
        let capabilities: [String]?
        let rate_limit_tier: String?
        let organization_type: String?
        var plan: String? {
            let tier = (rate_limit_tier ?? organization_type ?? "").lowercased()
            if tier.contains("enterprise") { return "Enterprise" }
            if tier.contains("team") { return "Team" }
            if tier.contains("max") { return "Max" }
            if tier.contains("pro") { return "Pro" }
            if tier.contains("free") { return "Free" }
            return nil
        }
    }

    private struct AccountResponse: Decodable {
        struct Membership: Decodable { let organization: Organization }
        let uuid: String
        let email_address: String
        let full_name: String?
        let memberships: [Membership]?
        var email: String { email_address.trimmingCharacters(in: .whitespacesAndNewlines) }
        var name: String? { full_name }
    }

    private func account(cookie: String, expectedAccountID: String) async throws -> AccountResponse {
        let data = try await get("/api/account", cookie: cookie, stage: .profile)
        guard let response = try? JSONDecoder().decode(AccountResponse.self, from: data), !response.email.isEmpty else {
            throw ClaudeUsageError.invalidResponse
        }
        guard let expected = UUID(uuidString: expectedAccountID), UUID(uuidString: response.uuid) == expected else {
            throw ClaudeUsageError.accountMismatch
        }
        return response
    }

    // 허용한 서비스에만 쿠키를 보내고 오류 응답 본문·인증값은 로그에 남기지 않는다.
    private func get(_ path: String, cookie: String, stage: ClaudeUsageStage) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://claude.ai" + path)!)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("sessionKey=\(cookie)", forHTTPHeaderField: "Cookie")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("https://claude.ai/", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ClaudeUsageClient.send(request, session: session)
        guard let response = response as? HTTPURLResponse, response.url?.scheme == "https",
              response.url?.host == "claude.ai" else { throw ClaudeUsageError.invalidResponse }
        if response.statusCode != 200 { stage.logFailure(status: response.statusCode) }
        switch response.statusCode {
        case 200:
            guard data.count <= 1_048_576 else { throw ClaudeUsageError.invalidResponse }
            return data
        case 401: throw ClaudeUsageError.signedOut
        // 접근 거부는 로그아웃과 구분해 재로그인을 잘못 안내하지 않는다.
        case 403: throw ClaudeUsageError.accessDenied(stage)
        case 429:
            let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let until = TimeInterval(value).map { Date().addingTimeInterval(max(1, $0)) }
                ?? formatter.date(from: value) ?? Date().addingTimeInterval(60)
            throw ClaudeUsageError.rateLimited(until)
        default: throw ClaudeUsageError.httpFailure(response.statusCode)
        }
    }
}
