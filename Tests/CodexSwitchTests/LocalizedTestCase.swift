import XCTest
@testable import CodexSwitch

// 기존 한국어 문구 검증은 CI의 시스템 언어와 무관하게 동일한 기준으로 실행한다.
class LocalizedTestCase: XCTestCase {
    private var previousLanguage: Any?

    override func setUp() {
        super.setUp()
        previousLanguage = UserDefaults.standard.object(forKey: L10n.preferenceKey)
        UserDefaults.standard.set("ko", forKey: L10n.preferenceKey)
    }

    override func tearDown() {
        if let previousLanguage {
            UserDefaults.standard.set(previousLanguage, forKey: L10n.preferenceKey)
        } else {
            UserDefaults.standard.removeObject(forKey: L10n.preferenceKey)
        }
        super.tearDown()
    }
}
