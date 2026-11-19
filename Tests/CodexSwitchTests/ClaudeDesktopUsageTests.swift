import Foundation
import XCTest
@testable import CodexSwitch

final class ClaudeDesktopUsageTests: XCTestCase {
    private let first = "11111111-1111-4111-8111-111111111111"
    private let second = "22222222-2222-4222-8222-222222222222"
    private let personal = "33333333-3333-4333-8333-333333333333"
    private let shared = "44444444-4444-4444-8444-444444444444"

    // 두 기간을 따로 읽어 5시간만·주간만·실제 0%·빈 값을 서로 다른 결과로 돌려준다.
    func testWindowsAreReadIndependently() throws {
        let cases: [(String, Double?, Double?)] = [
            (#"{"fh":12}"#, 12, nil),
            (#"{"sd":40}"#, nil, 40),
            (#"{"fh":0,"sd":0}"#, 0, 0),
            (#"{"fh":null,"sd":40}"#, nil, 40),
            (#"{"fh":"bad","sd":140}"#, nil, 100)
        ]
        for (usage, fiveHour, weekly) in cases {
            let history = Data(#"{"version":2,"samples":[{"t":5000,"org":"\#(personal)","u":\#(usage)}]}"#.utf8)
            let reading = ClaudeDesktopUsage.readings(history: history, sessions: [],
                                                      folders: [personal: [first]], accounts: [first])[first]
            XCTAssertEqual(reading, .sample(fiveHour: fiveHour, weekly: weekly, recordedAt: 5), usage)
        }
    }

    // 공식 화면의 사용률 40%는 60% 남음으로 표시되고, 값이 있는 가장 최근 표본을 쓴다.
    func testLatestValuedSampleBecomesRemainingPercent() throws {
        let history = Data(#"""
        {"version":2,"samples":[
          {"t":1000,"org":"\#(personal)","u":{"fh":5,"sd":10}},
          {"t":3000,"org":"\#(personal)","u":{}},
          {"t":2000,"org":"\#(personal)","u":{"fh":0,"sd":40}}
        ]}
        """#.utf8)
        let reading = ClaudeDesktopUsage.readings(history: history, sessions: [],
                                                  folders: [personal: [first]], accounts: [first])[first]
        guard case let .sample(fiveHour, weekly, recordedAt) = reading else { return XCTFail("표본을 읽지 못했습니다.") }
        XCTAssertEqual(recordedAt, 2)
        XCTAssertEqual(fiveHour, 0)
        let meter = try XCTUnwrap(UsageMeter(window: UsageWindow(usedPercent: try XCTUnwrap(weekly),
                                                                 windowMinutes: 10_080, resetsAt: nil)))
        XCTAssertEqual(meter.remainingPercent, 60)
    }

    // 공유 조직은 로그로 확인된 계정에만 붙이고, 확인할 수 없으면 추측하지 않는다.
    func testSharedOrganizationIsAttributedOnlyWithEvidence() {
        let history = Data(#"""
        {"version":2,"samples":[
          {"t":10000,"org":"\#(personal)","u":{"fh":1,"sd":2}},
          {"t":20000,"org":"\#(shared)","u":{"fh":30,"sd":40}},
          {"t":40000,"org":"\#(shared)","u":{"fh":70,"sd":80}}
        ]}
        """#.utf8)
        let folders: [String: Set<String>] = [personal: [first], shared: [first, second]]
        let withoutLog = ClaudeDesktopUsage.readings(history: history, sessions: [], folders: folders,
                                                     accounts: [first, second])
        XCTAssertEqual(withoutLog[first], .sample(fiveHour: 1, weekly: 2, recordedAt: 10))
        XCTAssertEqual(withoutLog[second], .ambiguous)

        // 같은 조직이어도 표본 직전에 불러온 계정이 다르면 각자의 기록으로 나뉜다.
        let sessions = [
            ClaudeDesktopUsage.Session(startedAtMS: 15_000, account: first, organization: shared),
            ClaudeDesktopUsage.Session(startedAtMS: 30_000, account: second, organization: shared)
        ]
        let withLog = ClaudeDesktopUsage.readings(history: history, sessions: sessions, folders: folders,
                                                  accounts: [first, second])
        XCTAssertEqual(withLog[first], .sample(fiveHour: 30, weekly: 40, recordedAt: 20))
        XCTAssertEqual(withLog[second], .sample(fiveHour: 70, weekly: 80, recordedAt: 40))
    }

    // 로그에서 다른 계정도 연 조직은 폴더가 한 계정에만 있어도 그 계정의 기록으로 단정하지 않는다.
    func testLogMembershipKeepsFolderEvidenceFromDecidingOwner() {
        let history = Data(#"{"version":2,"samples":[{"t":20000,"org":"\#(shared)","u":{"fh":30,"sd":40}}]}"#.utf8)
        let sessions = [ClaudeDesktopUsage.Session(startedAtMS: 30_000, account: second, organization: shared)]
        let readings = ClaudeDesktopUsage.readings(history: history, sessions: sessions,
                                                   folders: [shared: [first]], accounts: [first, second])
        XCTAssertEqual(readings[first], .ambiguous)
        XCTAssertEqual(readings[second], .ambiguous)
    }

    // 파일 없음·미지원 버전·빈 기록·기록 없음을 서로 다른 이유로 구분한다.
    func testMissingUnsupportedAndEmptyRecordsAreDistinct() {
        let folders: [String: Set<String>] = [personal: [first]]
        func reading(_ history: String?, account: String) -> ClaudeDesktopUsage.Reading? {
            ClaudeDesktopUsage.readings(history: history.map { Data($0.utf8) }, sessions: [], folders: folders,
                                        accounts: [account])[account]
        }
        XCTAssertEqual(reading(nil, account: first), .noRecord)
        XCTAssertEqual(reading(#"{"version":3,"samples":[]}"#, account: first), .unsupported)
        XCTAssertEqual(reading("not json", account: first), .unsupported)
        XCTAssertEqual(reading(#"{"version":2,"samples":[{"t":1,"org":"\#(personal)","u":{}}]}"#, account: first), .notProvided)
        XCTAssertEqual(reading(#"{"version":2,"samples":[{"t":1,"org":"\#(personal)","u":{"sd":1}}]}"#, account: second), .noRecord)
        XCTAssertEqual(reading(#"{"version":2,"samples":[{"org":"\#(personal)"},{"t":1}]}"#, account: first), .noRecord)
    }

    // 데스크톱 로그에서 계정을 불러온 줄만 순서대로 읽는다.
    func testParsesAccountLoadsFromDesktopLog() throws {
        let zone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let log = """
        2026-11-18 14:57:34 [info] [LocalSessionManager] Initialization succeeded — accountId=\(first), orgId=\(personal), existingSessions=0
        2026-11-18 14:57:40 [info] [plan-usage] background poll paused: tray not opened recently
        2026-11-18 14:57:56 [info] [LocalAgentModeSessionManager] Initialization succeeded — accountId=\(second.uppercased()), orgId=\(shared), existingSessions=0
        broken line accountId=\(first), orgId=\(shared)
        """
        let sessions = ClaudeDesktopUsage.sessions(log: Data(log.utf8), timeZone: zone)
        XCTAssertEqual(sessions, [
            ClaudeDesktopUsage.Session(startedAtMS: 1_794_981_454_000, account: first, organization: personal),
            ClaudeDesktopUsage.Session(startedAtMS: 1_794_981_476_000, account: second, organization: shared)
        ])
    }
}
