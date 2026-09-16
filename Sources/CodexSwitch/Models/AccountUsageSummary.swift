import Foundation

// 메뉴바와 계정 목록에서 같은 사용량 창·원본 기록 시각을 표시한다.
struct AccountUsageSummary {
    let menuBarText: String
    let menuText: String

    init(account: CodexAccount, now: Date = Date()) {
        let windows = [account.lastUsage?.primary, account.lastUsage?.secondary]
            .compactMap { $0 }
            .compactMap { window -> (UsageMeter, Bool)? in
                guard let meter = UsageMeter(window: window, now: now) else { return nil }
                let expired = window.resetsAt.map { TimeInterval($0) <= now.timeIntervalSince1970 } ?? false
                return (meter, expired)
            }
            .sorted { $0.0.windowMinutes < $1.0.windowMinutes }

        guard !windows.isEmpty else {
            menuBarText = L10n.text("사용량 —")
            menuText = L10n.text("사용량 정보 없음")
            return
        }

        // 초기화 시각이 지난 저장 값은 새 데이터 없이 100%로 추정하지 않는다.
        menuBarText = windows.map { meter, expired in
            let label = meter.windowMinutes == 10_080 ? L10n.text("주간") : meter.label
            return "\(label) \(expired ? "—" : "\(meter.remainingPercent)%")"
        }.joined(separator: " · ")
        let usage = windows.map { meter, expired in
            let label = meter.windowMinutes == 10_080 ? L10n.text("주간") : meter.label
            return expired ? L10n.text("%@ 재조회 필요", String(label)) : L10n.text("%@ %@%% 남음", String(label), String(meter.remainingPercent))
        }.joined(separator: " · ")
        menuText = "\(usage) · \(Self.ageText(timestamp: account.lastUsageAt, now: now))"
    }

    // 파일을 다시 읽은 시각(refreshedAt)과 사용량 자체가 기록된 시각을 혼동하지 않는다.
    private static func ageText(timestamp: Int64?, now: Date) -> String {
        guard let timestamp else { return L10n.text("조회 시각 없음") }
        let age = max(0, now.timeIntervalSince1970 - TimeInterval(timestamp))
        switch age {
        case ..<60: return L10n.text("방금")
        case ..<3_600: return L10n.text("%@분 전", String(Int(age / 60)))
        case ..<86_400: return L10n.text("%@시간 전", String(Int(age / 3_600)))
        default: return L10n.text("%@일 전", String(Int(age / 86_400)))
        }
    }
}
