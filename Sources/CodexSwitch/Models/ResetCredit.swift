import Foundation

// 일반 사용량 크레딧과 구분되는 초기화 쿠폰의 표시 정보만 보관한다.
struct ResetCredit: Decodable, Identifiable, Sendable, Equatable {
    let id: String
    let status: String
    let resetType: String
    let expiresAt: Date?

    enum CodingKeys: String, CodingKey {
        case id, status
        case resetType = "reset_type"
        case expiresAt = "expires_at"
    }

    // 사용 가능하고 아직 만료되지 않은 Codex 쿠폰을 만료일 순으로 정렬한다.
    static func available(in credits: [Self], at now: Date) -> [Self] {
        credits.filter {
            $0.status == "available" && $0.resetType == "codex_rate_limits"
                && ($0.expiresAt.map { $0 > now } ?? true)
        }.sorted {
            let left = $0.expiresAt ?? .distantFuture
            let right = $1.expiresAt ?? .distantFuture
            return left == right ? $0.id < $1.id : left < right
        }
    }
}

// 조회 실패와 실제 쿠폰 0장을 구분해 오래된 계정의 결과를 표시하지 않는다.
enum ResetCreditState: Sendable, Equatable {
    case loading
    case loaded([ResetCredit])
    case failed
}
