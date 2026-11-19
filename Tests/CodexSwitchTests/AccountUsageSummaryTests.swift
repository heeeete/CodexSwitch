import XCTest
@testable import CodexSwitch

final class AccountUsageSummaryTests: LocalizedTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    // 주간 한도가 primary에만 있어도 정확한 창 이름과 실제 기록 시각을 표시한다.
    func testWeeklyOnlyAndSavedDataAge() {
        let account = makeAccount(primary: window(minutes: 10_080, used: 19), age: 3_600 * 3)
        let summary = AccountUsageSummary(account: account, now: now)
        XCTAssertEqual(summary.menuBarText, "주간 81%")
        XCTAssertEqual(summary.menuText, "주간 81% 남음 · 3시간 전")
    }

    // 5시간 한도가 다시 들어오면 두 창을 함께 표시하고 고정된 가짜 한도를 만들지 않는다.
    func testBothWindowsAndFreshData() {
        let account = makeAccount(primary: window(minutes: 10_080, used: 19),
                                  secondary: window(minutes: 300, used: 26), age: 20)
        let summary = AccountUsageSummary(account: account, now: now)
        XCTAssertEqual(summary.menuBarText, "5h 74% · 주간 81%")
        XCTAssertEqual(summary.menuText, "5h 74% 남음 · 주간 81% 남음 · 방금")
        XCTAssertEqual(AccountUsageSummary(account: makeAccount(primary: window(minutes: 300, used: 100)),
                                           now: now).menuBarText, "5h 0%")
    }

    // 초기화가 지난 오래된 데이터와 사용량 자체가 없는 계정을 100%로 오인하지 않는다.
    func testExpiredAndMissingUsage() {
        let expired = UsageWindow(usedPercent: 95, windowMinutes: 300, resetsAt: 1_999_999_999)
        let summary = AccountUsageSummary(account: makeAccount(primary: expired,
                                         secondary: window(minutes: 10_080, used: 82), age: 172_800), now: now)
        XCTAssertEqual(summary.menuBarText, "5h — · 주간 18%")
        XCTAssertEqual(summary.menuText, "5h 재조회 필요 · 주간 18% 남음 · 2일 전")
        let missing = AccountUsageSummary(account: makeAccount(primary: nil), now: now)
        XCTAssertEqual(missing.menuBarText, "사용량 —")
        XCTAssertEqual(missing.menuText, "사용량 정보 없음")
    }

    // 모델별 주간 한도는 계정 목록 문구에만 이름과 함께 붙이고 메뉴 막대 문구는 그대로 둔다.
    func testModelWeeklyLimitAppearsOnlyInMenuText() {
        var account = makeAccount(primary: window(minutes: 300, used: 26),
                                  secondary: window(minutes: 10_080, used: 6), age: 20)
        account.lastUsage?.scoped = [
            UsageWindow(usedPercent: 11, windowMinutes: 10_080, resetsAt: 2_001_000_000, scope: "Fable"),
            UsageWindow(usedPercent: 50, windowMinutes: 10_080, resetsAt: 1_999_999_999, scope: "Opus")
        ]
        let summary = AccountUsageSummary(account: account, now: now)
        XCTAssertEqual(summary.menuBarText, "5h 74% · 주간 94%")
        XCTAssertEqual(summary.menuText, "5h 74% 남음 · 주간 94% 남음 · Fable 89% 남음 · Opus 재조회 필요 · 방금")
        let meter = UsageMeter(window: UsageWindow(usedPercent: 11, windowMinutes: 10_080, resetsAt: 2_000_345_600, scope: "Fable"), now: now)
        XCTAssertEqual(meter?.displayTitle, "Fable 주간 잔여량")
        XCTAssertEqual(meter?.dailyAllowance(at: now), 22)
    }

    func testMissingTimestampIsNotShownAsFresh() {
        var account = makeAccount(primary: window(minutes: 10_080, used: 19))
        account.lastUsageAt = nil
        XCTAssertEqual(AccountUsageSummary(account: account, now: now).menuText, "주간 81% 남음 · 조회 시각 없음")
    }

    private func window(minutes: Int, used: Double) -> UsageWindow {
        UsageWindow(usedPercent: used, windowMinutes: minutes, resetsAt: 2_001_000_000)
    }

    private func makeAccount(primary: UsageWindow?, secondary: UsageWindow? = nil, age: Int64 = 0) -> CodexAccount {
        CodexAccount(accountKey: "sample", email: "sample@example.com", alias: nil, accountName: nil,
                     plan: "pro", authMode: "chatgpt", lastUsedAt: nil, lastUsageAt: 2_000_000_000 - age,
                     lastUsage: UsageSnapshot(primary: primary, secondary: secondary, planType: "pro"))
    }
}
