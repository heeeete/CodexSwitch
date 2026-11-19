import Foundation

// Claude 데스크톱이 직접 남긴 사용률 표본을 해석하며 키체인이나 네트워크를 쓰지 않는다.
enum ClaudeDesktopUsage {
    enum Reading: Equatable, Sendable {
        case sample(fiveHour: Double?, weekly: Double?, recordedAt: Int64)
        case noRecord
        case notProvided
        case unsupported
        case ambiguous
    }

    // 데스크톱이 계정을 불러온 시각과 그때 열린 조직이다.
    struct Session: Equatable, Sendable {
        let startedAtMS: Int64
        let account: String
        let organization: String
    }

    // 표본에는 조직만 있으므로 계정과의 연결이 확인된 표본만 해당 계정에 붙인다.
    static func readings(
        history: Data?,
        sessions: [Session],
        folders: [String: Set<String>],
        accounts: [String]
    ) -> [String: Reading] {
        func all(_ reading: Reading) -> [String: Reading] {
            Dictionary(accounts.map { ($0, reading) }, uniquingKeysWith: { first, _ in first })
        }
        guard let history else { return all(.noRecord) }
        // 내부 형식이 바뀐 버전은 추측해서 읽지 않는다.
        guard let root = try? JSONSerialization.jsonObject(with: history) as? [String: Any],
              (root["version"] as? NSNumber)?.intValue == 2,
              let samples = root["samples"] as? [[String: Any]] else { return all(.unsupported) }

        // 로그에서 같은 조직을 연 계정도 후보에 넣어, 폴더가 한쪽에만 있다는 이유로 공유 조직을 한 계정에 붙이지 않는다.
        var members = folders
        for session in sessions { members[session.organization, default: []].insert(session.account) }
        var latest: [String: Reading] = [:]
        var owned: Set<String> = []
        var ambiguous: Set<String> = []
        let ordered = samples.compactMap { sample -> (Int64, String, [String: Any])? in
            guard let time = (sample["t"] as? NSNumber)?.int64Value, let organization = sample["org"] as? String else { return nil }
            return (time, organization.lowercased(), sample["u"] as? [String: Any] ?? [:])
        }.sorted { $0.0 < $1.0 }
        for (time, organization, usage) in ordered {
            let owner: String
            if let session = sessions.last(where: { $0.startedAtMS <= time }), session.organization == organization {
                // 표본 직전에 이 조직으로 불러온 계정이 로그에 남아 있으면 그 계정의 기록이다.
                owner = session.account
            } else {
                // 표본 시점의 로그가 없으면 한 계정만 쓰는 조직일 때만 귀속하고, 공유 조직은 추측하지 않는다.
                let candidates = members[organization] ?? []
                guard candidates.count == 1, let only = candidates.first else {
                    ambiguous.formUnion(candidates)
                    continue
                }
                owner = only
            }
            owned.insert(owner)
            // 미제공 값은 nil로 남겨 실제 사용률 0%와 구분한다.
            func percent(_ key: String) -> Double? {
                guard let value = (usage[key] as? NSNumber)?.doubleValue, value.isFinite, value >= 0 else { return nil }
                return min(value, 100)
            }
            let fiveHour = percent("fh")
            let weekly = percent("sd")
            if fiveHour != nil || weekly != nil {
                latest[owner] = .sample(fiveHour: fiveHour, weekly: weekly, recordedAt: time / 1_000)
            }
        }
        return Dictionary(accounts.map { account in
            let key = account.lowercased()
            if let reading = latest[key] { return (account, reading) }
            if owned.contains(key) { return (account, .notProvided) }
            return (account, ambiguous.contains(key) ? .ambiguous : .noRecord)
        }, uniquingKeysWith: { first, _ in first })
    }

    // 로그 시각은 시간대 표기가 없는 현지 시각이며 파일 순서를 그대로 유지한다.
    static func sessions(log: Data, timeZone: TimeZone = .current) -> [Session] {
        let pattern = #"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) .*Initialization succeeded.*accountId=([0-9a-fA-F-]{36}), orgId=([0-9a-fA-F-]{36})"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let text = String(decoding: log, as: UTF8.self)
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let time = Range(match.range(at: 1), in: text), let account = Range(match.range(at: 2), in: text),
                  let organization = Range(match.range(at: 3), in: text),
                  let date = formatter.date(from: String(text[time])) else { return nil }
            return Session(startedAtMS: Int64(date.timeIntervalSince1970 * 1_000),
                           account: text[account].lowercased(), organization: text[organization].lowercased())
        }
    }
}
