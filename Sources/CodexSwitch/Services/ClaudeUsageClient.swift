import CommonCrypto
import Foundation
import LocalAuthentication
import Security

// 서버 오류 본문과 인증값을 사용자 안내나 로그에 포함하지 않는다.
enum ClaudeUsageError: LocalizedError, Equatable {
    case invalidCredential
    case keychainUnavailable
    case tokenExpired
    case signedOut
    case accessDenied(ClaudeUsageStage)
    case accountMismatch
    case invalidResponse
    case connectionFailed
    case rateLimited(Date)
    case httpFailure(Int)
    case usageNotProvided
    case notSubscribed
    case noLocalRecord
    case unsupportedLocalRecord
    case ambiguousOrganization
    case staleLocalRecord(Date)

    var errorDescription: String? {
        switch self {
        case .invalidCredential:
            L10n.text("Claude 인증 정보를 읽지 못했습니다. 계정을 다시 추가해 주세요.")
        case .keychainUnavailable:
            L10n.text("Claude 키체인에 접근하지 못했습니다. 새로고침 버튼을 눌러 접근을 허용해 주세요.")
        case .tokenExpired:
            L10n.text("Claude 인증 갱신이 필요합니다. 이 계정으로 Claude를 연 뒤 새로고침해 주세요.")
        case .signedOut:
            L10n.text("Claude 로그인을 확인해 주세요. 해당 계정으로 Claude를 열어 로그인한 뒤 새로고침해 주세요.")
        case let .accessDenied(stage):
            L10n.text("Claude가 %@ 조회를 거부했습니다. 로그인 문제가 아닐 수 있으니 잠시 후 다시 시도해 주세요.", stage.title)
        case .accountMismatch:
            L10n.text("Claude 인증이 선택한 계정과 일치하지 않아 작업을 중단했습니다.")
        case .invalidResponse:
            L10n.text("Claude 사용량 응답을 읽지 못했습니다. 잠시 후 다시 시도해 주세요.")
        case .rateLimited:
            L10n.text("Claude 조회가 일시적으로 제한됐습니다. 마지막 사용량을 유지하고 잠시 후 다시 조회합니다.")
        case let .httpFailure(status):
            L10n.text("Claude 조회에 실패했습니다. 잠시 후 다시 시도해 주세요. (%@)", String(status))
        case .connectionFailed:
            L10n.text("Claude 서버에 연결하지 못했습니다. 네트워크를 확인한 뒤 새로고침해 주세요.")
        case .usageNotProvided:
            L10n.text("Claude가 이 계정의 5시간·주간 사용량을 제공하지 않았습니다.")
        case .notSubscribed:
            L10n.text("구독 중인 요금제가 없는 계정입니다. 요금제를 구독하면 5시간·주간 사용량이 표시됩니다.")
        case .noLocalRecord:
            L10n.text("Claude가 이 계정의 사용량을 아직 기록하지 않았습니다. 이 계정으로 Claude를 연 뒤 새로고침해 주세요.")
        case .unsupportedLocalRecord:
            L10n.text("이 Claude 버전의 사용량 기록 형식은 아직 지원하지 않습니다. CodexSwitch를 업데이트해 주세요.")
        case .ambiguousOrganization:
            L10n.text("같은 조직을 여러 계정이 사용해 기록의 주인을 구분하지 못했습니다. 이 계정으로 Claude를 다시 연 뒤 새로고침해 주세요.")
        case let .staleLocalRecord(date):
            L10n.text("마지막 기록(%@)이 오래돼 현재 사용량을 알 수 없습니다. 이 계정으로 Claude를 연 뒤 새로고침해 주세요.",
                      date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened, locale: Locale(identifier: L10n.language))))
        }
    }
}

// 실패한 요청이 어느 단계였는지 사용자 안내와 개발자 로그에 함께 남긴다.
enum ClaudeUsageStage: String, Sendable {
    case profile, organization, usage

    var title: String {
        switch self {
        case .profile: L10n.text("프로필")
        case .organization: L10n.text("조직")
        case .usage: L10n.text("사용량")
        }
    }

    // 응답 본문과 인증값 없이 단계와 상태 코드만 기록한다.
    func logFailure(status: Int) {
        NSLog("CodexSwitch Claude request failed: stage=%@ status=%d", rawValue, status)
    }
}

struct ClaudeProfile: Sendable, Equatable {
    let accountID: String
    let email: String
    let displayName: String?
    let plan: String?
}

// 데스크톱이 암호화한 캐시만 읽으며 토큰을 디스크나 프로세스 인자에 기록하지 않는다.
struct ClaudeUsageClient: Sendable {
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
        encryptedCache: String,
        expectedAccountID: String,
        allowKeychainPrompt: Bool = false
    ) async throws -> ClaudeProfile {
        let token = try accessToken(encryptedCache, accountID: expectedAccountID, allowKeychainPrompt: allowKeychainPrompt)
        return try await verifiedProfile(token: token, accountID: expectedAccountID)
    }

    // 사용량도 실제 서버 계정을 먼저 검증해 다른 계정의 숫자가 섞이지 않게 한다.
    func usage(
        encryptedCache: String,
        expectedAccountID: String,
        allowKeychainPrompt: Bool = false
    ) async throws -> UsageSnapshot {
        try await profileAndUsage(encryptedCache: encryptedCache, expectedAccountID: expectedAccountID,
                                  allowKeychainPrompt: allowKeychainPrompt).usage
    }

    // 계정 목록 갱신은 한 번의 복호화와 프로필 조회로 메타데이터와 사용량을 함께 가져온다.
    func profileAndUsage(
        encryptedCache: String,
        expectedAccountID: String,
        allowKeychainPrompt: Bool = false
    ) async throws -> (profile: ClaudeProfile, usage: UsageSnapshot) {
        let token = try accessToken(encryptedCache, accountID: expectedAccountID, allowKeychainPrompt: allowKeychainPrompt)
        let profile = try await verifiedProfile(token: token, accountID: expectedAccountID)
        let data = try await get("/api/oauth/usage", token: token, stage: .usage)
        return (profile, try Self.decodeUsage(data, plan: profile.plan))
    }

    private func accessToken(_ cache: String, accountID: String, allowKeychainPrompt: Bool) throws -> String {
        struct Entry: Decodable {
            let token: String?
            let expiresAt: Int64?
        }
        guard !accountID.isEmpty else { throw ClaudeUsageError.invalidCredential }
        let plain = try decrypt(cache, allowKeychainPrompt)
        guard let entries = try? JSONDecoder().decode([String: Entry].self, from: plain) else {
            throw ClaudeUsageError.invalidCredential
        }
        let now = Int64(Date().timeIntervalSince1970 * 1_000)
        let candidates = entries.filter { key, _ in
            key.hasPrefix("acct:\(accountID)|") && key.contains("user:profile")
        }
        let token = candidates.filter { _, value in
            (value.expiresAt ?? 0) > now
                && value.token.map { !$0.isEmpty && $0.unicodeScalars.allSatisfy { (33...126).contains($0.value) } } == true
        }.max { ($0.value.expiresAt ?? 0) < ($1.value.expiresAt ?? 0) }?.value.token
        guard let token else {
            if candidates.contains(where: { ($0.value.expiresAt ?? 0) > 0 && ($0.value.expiresAt ?? 0) <= now }) {
                throw ClaudeUsageError.tokenExpired
            }
            throw ClaudeUsageError.invalidCredential
        }
        return token
    }

    // 캐시·쿠키 저장과 리다이렉트를 막아 계정 응답과 Bearer 토큰을 메모리 안에만 둔다.
    static func ephemeralSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: ClaudeRedirectBlocker(), delegateQueue: nil)
    }

    private func verifiedProfile(token: String, accountID: String) async throws -> ClaudeProfile {
        struct Response: Decodable {
            struct Account: Decodable {
                let uuid: String
                let email: String
                let display_name: String?
                let has_claude_max: Bool?
                let has_claude_pro: Bool?
            }
            struct Organization: Decodable { let organization_type: String? }
            let account: Account
            let organization: Organization?
        }
        let data = try await get("/api/oauth/profile", token: token, stage: .profile)
        guard let response = try? JSONDecoder().decode(Response.self, from: data),
              !response.account.email.isEmpty else { throw ClaudeUsageError.invalidResponse }
        guard response.account.uuid == accountID else { throw ClaudeUsageError.accountMismatch }
        let type = response.organization?.organization_type?.replacingOccurrences(of: "claude_", with: "")
        let plan: String?
        if let type, ["pro", "max", "team", "enterprise"].contains(type) {
            plan = type.capitalized
        } else if response.account.has_claude_max == true {
            plan = "Max"
        } else if response.account.has_claude_pro == true {
            plan = "Pro"
        } else {
            plan = nil
        }
        return ClaudeProfile(accountID: accountID, email: response.account.email,
                             displayName: response.account.display_name, plan: plan)
    }

    // 고정된 Anthropic 주소에만 요청하며 쿠키와 응답 캐시를 사용하지 않는다.
    private func get(_ path: String, token: String, stage: ClaudeUsageStage) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://api.anthropic.com" + path)!)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("CodexSwitch", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await ClaudeUsageClient.send(request, session: session)
        guard let response = response as? HTTPURLResponse,
              response.url?.scheme == "https", response.url?.host == "api.anthropic.com" else {
            throw ClaudeUsageError.invalidResponse
        }
        if response.statusCode != 200 { stage.logFailure(status: response.statusCode) }
        switch response.statusCode {
        case 200:
            guard data.count <= 1_048_576 else { throw ClaudeUsageError.invalidResponse }
            return data
        case 401:
            throw ClaudeUsageError.signedOut
        case 403:
            // 접근 거부는 로그아웃과 구분해 재로그인을 잘못 안내하지 않는다.
            throw ClaudeUsageError.accessDenied(stage)
        case 429:
            let value = response.value(forHTTPHeaderField: "Retry-After") ?? ""
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            let retry = TimeInterval(value).map { Date().addingTimeInterval(max(1, $0)) }
                ?? formatter.date(from: value) ?? Date().addingTimeInterval(60)
            throw ClaudeUsageError.rateLimited(retry)
        default:
            throw ClaudeUsageError.httpFailure(response.statusCode)
        }
    }

    // 연결 실패는 시스템 오류 문구 대신 원인과 다음 행동을 안내할 수 있게 구분한다.
    static func send(_ request: URLRequest, session: URLSession) async throws -> (Data, URLResponse) {
        do {
            return try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            NSLog("CodexSwitch Claude request failed: path=%@ code=%d", request.url?.path ?? "", error.code.rawValue)
            throw ClaudeUsageError.connectionFailed
        }
    }

    // 두 기간을 따로 변환해 한쪽의 빈 값이나 잘못된 값이 다른 쪽의 정상 수치를 버리지 않게 한다.
    static func decodeUsage(_ data: Data, plan: String? = nil) throws -> UsageSnapshot {
        guard let response = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              response["five_hour"] != nil || response["seven_day"] != nil else {
            throw ClaudeUsageError.invalidResponse
        }
        var invalid = false
        // 읽을 수 없는 초기화 시각은 추정하지 않고 사용률만 표시한다.
        func reset(_ value: [String: Any]) -> Int64? {
            guard let text = value["resets_at"] as? String else { return nil }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            return (formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)).map { Int64($0.timeIntervalSince1970) }
        }
        func window(_ key: String, minutes: Int) -> UsageWindow? {
            // 기간이나 사용률이 null이면 0%로 만들지 않고 미제공으로 둔다.
            guard let value = response[key] as? [String: Any], let raw = value["utilization"] as? NSNumber else { return nil }
            let used = raw.doubleValue
            guard used.isFinite, used >= 0 else {
                invalid = true
                return nil
            }
            return UsageWindow(usedPercent: min(used, 100), windowMinutes: minutes, resetsAt: reset(value))
        }
        let fiveHour = window("five_hour", minutes: 300)
        let weekly = window("seven_day", minutes: 10_080)
        // 표시할 값이 하나도 없는데 잘못된 비율만 있었다면 미제공이 아니라 응답 오류다.
        if fiveHour == nil, weekly == nil, invalid { throw ClaudeUsageError.invalidResponse }
        // 특정 모델에만 걸린 주간 한도는 limits 목록에 모델 이름과 함께 오며, 이름이나 비율을 읽을 수 없는 항목은 건너뛴다.
        let scoped = (response["limits"] as? [[String: Any]] ?? []).compactMap { limit -> UsageWindow? in
            guard limit["group"] as? String == "weekly",
                  let model = (limit["scope"] as? [String: Any])?["model"] as? [String: Any],
                  let name = (model["display_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
                  let used = (limit["percent"] as? NSNumber)?.doubleValue, used.isFinite, used >= 0 else { return nil }
            return UsageWindow(usedPercent: min(used, 100), windowMinutes: 10_080, resetsAt: reset(limit), scope: name)
        }
        return UsageSnapshot(primary: fiveHour, secondary: weekly, planType: plan, scoped: scoped.isEmpty ? nil : scoped)
    }
}

// 프로덕션 세션은 30x 응답을 그대로 오류로 돌려 인증 헤더의 다른 주소 전달을 막는다.
private final class ClaudeRedirectBlocker: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Electron의 macOS v10 저장 형식을 사용하고 기존 Claude 키체인 항목을 변경하지 않는다.
enum ClaudeCredentialCipher {
    private static let interactionLock = NSLock()

    static func decrypt(_ value: String, allowInteraction: Bool = false) throws -> Data {
        guard let encrypted = Data(base64Encoded: value), encrypted.count >= 19,
              encrypted.prefix(3) == Data("v10".utf8), (encrypted.count - 3).isMultiple(of: 16) else {
            throw ClaudeUsageError.invalidCredential
        }
        // 로그인 키체인의 승인창은 LAContext 설정만으로 막히지 않아 자동 조회가 승인창에서 멈춘다.
        // 자동 조회 동안에만 이 프로세스의 키체인 승인창을 끄고, 끝나면 수동 조회를 위해 되돌린다.
        interactionLock.lock()
        defer { interactionLock.unlock() }
        if !allowInteraction { SecKeychainSetUserInteractionAllowed(false) }
        defer { if !allowInteraction { SecKeychainSetUserInteractionAllowed(true) } }
        let context = LAContext()
        context.interactionNotAllowed = !allowInteraction
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Safe Storage",
            kSecAttrAccount as String: "Claude Key",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationContext as String: context
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let password = result as? Data else { throw ClaudeUsageError.keychainUnavailable }
        return try decrypt(value, password: password)
    }

    static func decrypt(_ value: String, password: Data) throws -> Data {
        guard let encrypted = Data(base64Encoded: value), encrypted.count >= 19,
              encrypted.prefix(3) == Data("v10".utf8), (encrypted.count - 3).isMultiple(of: 16) else {
            throw ClaudeUsageError.invalidCredential
        }
        var key = Data(count: kCCKeySizeAES128)
        let salt = Data("saltysalt".utf8)
        let derived = key.withUnsafeMutableBytes { keyBytes in
            password.withUnsafeBytes { passwordBytes in
                salt.withUnsafeBytes { saltBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                        passwordBytes.bindMemory(to: Int8.self).baseAddress, password.count,
                                        saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1), 1003,
                                        keyBytes.bindMemory(to: UInt8.self).baseAddress, kCCKeySizeAES128)
                }
            }
        }
        guard derived == kCCSuccess else { throw ClaudeUsageError.invalidCredential }
        let cipher = Data(encrypted.dropFirst(3))
        let iv = Data(repeating: 32, count: kCCBlockSizeAES128)
        var output = Data(count: cipher.count + kCCBlockSizeAES128)
        var length = 0
        let outputCapacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            cipher.withUnsafeBytes { input in
                key.withUnsafeBytes { key in
                    iv.withUnsafeBytes { iv in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                key.baseAddress, kCCKeySizeAES128, iv.baseAddress, input.baseAddress, cipher.count,
                                out.baseAddress, outputCapacity, &length)
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw ClaudeUsageError.invalidCredential }
        return Data(output.prefix(length))
    }
}
