import Foundation

// helper가 버리는 limit_id를 확인해 일반 Codex의 로컬 사용량만 선택한다.
struct LocalUsageReader {
    struct Reading {
        let timestamp: Date
        let usage: UsageSnapshot
    }

    private struct CachedFile {
        let modified: Date?
        let size: Int?
        let reading: Reading?
    }
    private var cache: [URL: CachedFile] = [:]

    // 변경된 파일만 다시 읽고, 계정 전환 이전의 기록은 현재 계정에 적용하지 않는다.
    mutating func latest(in sessionsURL: URL, since activatedAt: Date) -> Reading? {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(
            at: sessionsURL, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return nil }
        let candidates = files.compactMap { value -> (URL, URLResourceValues)? in
            guard let url = value as? URL, url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl", let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return (url, values)
        }.sorted { ($0.1.contentModificationDate ?? .distantPast) > ($1.1.contentModificationDate ?? .distantPast) }
        var latest: Reading?
        // upstream과 같은 최근 세션 중심 조회를 유지하되 일반 Codex 기록을 더 넓게 찾는다.
        let recent = candidates.prefix(64)
        cache = cache.filter { entry in recent.contains { $0.0 == entry.key } }
        for (url, values) in recent {
            let cached = cache[url]
            let reading: Reading?
            if let cached, cached.modified == values.contentModificationDate, cached.size == values.fileSize {
                reading = cached.reading
            } else {
                reading = try? read(url)
                cache[url] = CachedFile(modified: values.contentModificationDate, size: values.fileSize, reading: reading)
            }
            if let reading, reading.timestamp >= activatedAt,
               latest == nil || reading.timestamp > latest!.timestamp {
                latest = reading
            }
        }
        return latest
    }

    // 뒤에 추가되는 세션 기록을 역순으로 읽어 큰 대화의 본문까지 훑지 않는다.
    private func read(_ url: URL) throws -> Reading? {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        var offset = try file.seekToEnd()
        var pending = Data()
        let decoder = JSONDecoder()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        while offset > 0 {
            let length = min(offset, 64 * 1024)
            offset -= length
            try file.seek(toOffset: offset)
            var chunk = try file.read(upToCount: Int(length)) ?? Data()
            chunk.append(pending)
            var end = chunk.endIndex
            while let newline = chunk[..<end].lastIndex(of: 10) {
                let line = chunk[chunk.index(after: newline)..<end]
                if let reading = parse(line, decoder: decoder, formatter: formatter) { return reading }
                end = newline
            }
            // 청크 경계를 가로지르는 줄은 앞부분을 더 읽은 뒤 파싱한다.
            pending = Data(chunk[..<end])
        }
        return parse(pending, decoder: decoder, formatter: formatter)
    }

    // limit_id가 없는 구형 Codex 기록도 읽되 Spark 등 별도 사용량은 제외한다.
    private func parse(_ line: Data, decoder: JSONDecoder, formatter: ISO8601DateFormatter) -> Reading? {
        guard line.range(of: Data("\"rate_limits\"".utf8)) != nil,
              let event = try? decoder.decode(Event.self, from: line),
              event.type == "event_msg", event.payload.type == "token_count",
              let limits = event.payload.rateLimits,
              limits.limitID == nil || limits.limitID == "codex" else { return nil }
        guard let date = formatter.date(from: event.timestamp)
            ?? ISO8601DateFormatter().date(from: event.timestamp) else { return nil }
        return Reading(timestamp: date, usage: UsageSnapshot(
            primary: limits.primary, secondary: limits.secondary, planType: limits.planType
        ))
    }

    private struct Event: Decodable {
        let timestamp: String
        let type: String
        let payload: Payload
        struct Payload: Decodable {
            let type: String
            let rateLimits: Limits?
            enum CodingKeys: String, CodingKey { case type; case rateLimits = "rate_limits" }
        }
        struct Limits: Decodable {
            let limitID: String?
            let primary: UsageWindow?
            let secondary: UsageWindow?
            let planType: String?
            enum CodingKeys: String, CodingKey {
                case primary, secondary
                case limitID = "limit_id"
                case planType = "plan_type"
            }
        }
    }
}
