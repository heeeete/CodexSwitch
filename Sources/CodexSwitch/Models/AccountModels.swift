import Foundation

// codex-auth가 관리하는 로컬 registry.json의 필요한 필드만 디코딩한다.
struct AccountRegistry: Decodable, Sendable {
    let schemaVersion: Int
    let activeAccountKey: String?
    let api: APIConfiguration?
    let accounts: [CodexAccount]

    static let empty = AccountRegistry(
        schemaVersion: 3,
        activeAccountKey: nil,
        api: nil,
        accounts: []
    )

    init(
        schemaVersion: Int,
        activeAccountKey: String?,
        api: APIConfiguration?,
        accounts: [CodexAccount]
    ) {
        self.schemaVersion = schemaVersion
        self.activeAccountKey = activeAccountKey
        self.api = api
        self.accounts = accounts
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case activeAccountKey = "active_account_key"
        case api
        case accounts
    }
}

// stable codex-auth가 registry에 저장하는 API 사용 설정이다.
struct APIConfiguration: Decodable, Sendable {
    let usage: Bool
    let account: Bool
}

// 인증 토큰을 제외한 계정 표시용 메타데이터다.
struct CodexAccount: Decodable, Identifiable, Sendable {
    let accountKey: String
    let email: String
    let alias: String?
    let accountName: String?
    let plan: String?
    let authMode: String?
    let lastUsedAt: Int64?
    let lastUsageAt: Int64?
    let lastUsage: UsageSnapshot?

    var id: String { accountKey }

    var displayName: String {
        let trimmedAlias = alias?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAlias.isEmpty {
            return trimmedAlias
        }

        let trimmedAccountName = accountName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmedAccountName.isEmpty {
            return trimmedAccountName
        }

        return email
    }

    var displayPlan: String {
        let usagePlan = lastUsage?.planType?.trimmingCharacters(in: .whitespacesAndNewlines)
        let storedPlan = plan?.trimmingCharacters(in: .whitespacesAndNewlines)
        // helper가 알 수 없는 플랜을 반환한 경우 registry의 원본 플랜을 보존한다.
        let meaningfulUsagePlan = usagePlan?.lowercased() == "unknown" ? nil : usagePlan
        guard let resolvedPlan = [meaningfulUsagePlan, storedPlan]
            .compactMap({ $0 })
            .first(where: { !$0.isEmpty }) else {
            return "Unknown"
        }

        // codex-auth의 Pro Lite/Pro 구분을 현재 Codex 사용량 배율로 표시한다.
        switch resolvedPlan.lowercased() {
        case "prolite":
            return "Pro ×5"
        case "pro":
            return "Pro ×20"
        case "go":
            return "Go"
        default:
            return resolvedPlan.prefix(1).uppercased() + resolvedPlan.dropFirst()
        }
    }

    var usageMeters: [UsageMeter] {
        guard let lastUsage else { return [] }
        return [lastUsage.primary, lastUsage.secondary]
            .compactMap { $0 }
            .compactMap { UsageMeter(window: $0) }
            .sorted { $0.windowMinutes < $1.windowMinutes }
    }

    enum CodingKeys: String, CodingKey {
        case accountKey = "account_key"
        case email
        case alias
        case accountName = "account_name"
        case plan
        case authMode = "auth_mode"
        case lastUsedAt = "last_used_at"
        case lastUsageAt = "last_usage_at"
        case lastUsage = "last_usage"
    }
}

// 사용량 응답은 세션 창과 주간 창을 최대 두 개까지 보관한다.
struct UsageSnapshot: Decodable, Sendable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let planType: String?

    enum CodingKeys: String, CodingKey {
        case primary
        case secondary
        case planType = "plan_type"
    }
}

struct UsageWindow: Decodable, Sendable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Int64?

    enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case windowMinutes = "window_minutes"
        case resetsAt = "resets_at"
    }
}

// 화면에서 사용할 남은 비율과 창 이름을 원본 사용량에서 계산한다.
struct UsageMeter: Identifiable, Equatable, Sendable {
    let windowMinutes: Int
    let remainingPercent: Int
    let resetsAt: Date?

    var id: Int { windowMinutes }

    init?(window: UsageWindow, now: Date = Date()) {
        guard let windowMinutes = window.windowMinutes else { return nil }

        self.windowMinutes = windowMinutes
        let resetDate = window.resetsAt.map { Date(timeIntervalSince1970: TimeInterval($0)) }

        // 이미 끝난 창은 다시 사용 가능한 상태로 표시하고 과거 재설정 시각은 숨긴다.
        if let resetDate, resetDate <= now {
            remainingPercent = 100
            resetsAt = nil
        } else {
            remainingPercent = max(0, min(100, Int((100 - window.usedPercent).rounded())))
            resetsAt = resetDate
        }
    }

    var label: String {
        switch windowMinutes {
        case ...360:
            return "5h"
        case 9_000...11_000:
            return "7d"
        default:
            let hours = max(1, windowMinutes / 60)
            return "\(hours)h"
        }
    }

    // 정확한 reset timestamp를 메뉴에 맞는 짧은 남은 시간으로 바꾼다.
    func resetCountdown(at now: Date = Date()) -> String? {
        guard let resetsAt else { return nil }
        let totalSeconds = max(0, Int(resetsAt.timeIntervalSince(now)))
        let days = totalSeconds / 86_400
        let hours = (totalSeconds % 86_400) / 3_600
        let minutes = (totalSeconds % 3_600) / 60

        if days > 0 {
            return "\(days)d \(hours)h"
        }
        if hours > 0 {
            return "\(hours)h \(minutes)m"
        }
        if minutes > 0 {
            return "\(minutes)m"
        }
        return totalSeconds > 0 ? "<1m" : "0m"
    }
}

// 화면 동작은 변하지 않는 account_key를 식별자로 사용한다.
struct AccountListItem: Identifiable, Sendable {
    let account: CodexAccount

    var id: String { account.id }
}
