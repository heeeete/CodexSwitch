import Foundation

// 쿠폰은 사용량 조회 모드와 별개로 OpenAI에 GET 요청만 보낸다.
enum ResetCreditClient {
    static func fetch(request: URLRequest, session: URLSession) async throws -> [ResetCredit] {
        let (data, response) = try await session.data(for: request, delegate: NoRedirect())
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return try decode(data)
    }

    // 서버의 소수점 유무가 다른 ISO 8601 만료 시각을 모두 읽는다.
    static func decode(_ data: Data) throws -> [ResetCredit] {
        struct Response: Decodable { let credits: [ResetCredit] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let value = try decoder.singleValueContainer().decode(String.self)
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: value) { return date }
            formatter.formatOptions = [.withInternetDateTime]
            if let date = formatter.date(from: value) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "Invalid coupon expiration date"
            ))
        }
        return try decoder.decode(Response.self, from: data).credits
    }

    // 인증 헤더가 붙은 요청은 다른 URL로 따라가지 않는다.
    private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping @Sendable (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
