import Foundation
import XCTest
@testable import CodexSwitch

final class AccountModelsTests: XCTestCase {
    // 실제 registry 구조와 같은 fixture가 필요한 필드를 올바르게 읽는지 확인한다.
    func testRegistryDecodingAndUsageMapping() throws {
        let json = #"""
        {
          "schema_version": 3,
          "active_account_key": "account-a",
          "api": {
            "usage": false,
            "account": false
          },
          "accounts": [
            {
              "account_key": "account-a",
              "email": "person@example.com",
              "alias": "Work",
              "account_name": null,
              "plan": "pro",
              "auth_mode": "chatgpt",
              "last_used_at": 1700000000,
              "last_usage_at": 1700000001,
              "last_usage": {
                "plan_type": "pro",
                "primary": {
                  "used_percent": 7.5,
                  "window_minutes": 300,
                  "resets_at": 2100000300
                },
                "secondary": {
                  "used_percent": 41.25,
                  "window_minutes": 10080,
                  "resets_at": 2100600000
                }
              }
            }
          ]
        }
        """#

        let registry = try JSONDecoder().decode(
            AccountRegistry.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(registry.schemaVersion, 3)
        XCTAssertEqual(registry.activeAccountKey, "account-a")
        XCTAssertEqual(registry.api?.usage, false)
        XCTAssertEqual(registry.api?.account, false)
        XCTAssertEqual(registry.accounts.first?.displayName, "Work")
        XCTAssertEqual(registry.accounts.first?.displayPlan, "Pro ×20")
        XCTAssertEqual(registry.accounts.first?.usageMeters.map(\.label), ["5h", "7d"])
        XCTAssertEqual(registry.accounts.first?.usageMeters.map(\.remainingPercent), [93, 59])
    }

    // 표시 이름은 별칭, 계정명, 이메일 순서로 선택한다.
    func testDisplayNameFallback() throws {
        let json = #"""
        {
          "account_key": "account-b",
          "email": "fallback@example.com",
          "alias": "",
          "account_name": "Personal",
          "plan": null,
          "last_used_at": null,
          "last_usage_at": null,
          "last_usage": null
        }
        """#

        let account = try JSONDecoder().decode(
            CodexAccount.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(account.displayName, "Personal")
        XCTAssertEqual(account.displayPlan, "Unknown")
        XCTAssertTrue(account.usageMeters.isEmpty)
    }

    // 최신 사용량의 Pro Lite 플랜은 저장된 플랜보다 우선하며 5배 배율로 표시한다.
    func testUsagePlanOverridesStoredPlan() throws {
        let json = #"""
        {
          "account_key": "account-c",
          "email": "prolite@example.com",
          "alias": null,
          "account_name": null,
          "plan": "pro",
          "last_used_at": null,
          "last_usage_at": 1700000001,
          "last_usage": {
            "plan_type": "prolite",
            "primary": null,
            "secondary": null
          }
        }
        """#

        let account = try JSONDecoder().decode(
            CodexAccount.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(account.displayPlan, "Pro ×5")
    }

    // helper의 unknown 플랜은 registry에 저장된 Go 플랜을 가리지 않는다.
    func testStoredGoPlanUsedWhenUsagePlanIsUnknown() throws {
        let json = #"""
        {
          "account_key": "account-go",
          "email": "go@example.com",
          "alias": null,
          "account_name": null,
          "plan": "go",
          "last_used_at": null,
          "last_usage_at": 2100000000,
          "last_usage": {
            "plan_type": "unknown",
            "primary": null,
            "secondary": null
          }
        }
        """#

        let account = try JSONDecoder().decode(
            CodexAccount.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(account.displayPlan, "Go")
    }

    // window_minutes가 null인 창은 registry 디코딩을 막지 않고 미터에서 제외한다.
    func testNullWindowMinutesOmittedFromUsageMeters() throws {
        let json = #"""
        {
          "schema_version": 3,
          "active_account_key": "account-null-window",
          "api": null,
          "accounts": [
            {
              "account_key": "account-null-window",
              "email": "null-window@example.com",
              "alias": null,
              "account_name": null,
              "plan": "go",
              "last_used_at": null,
              "last_usage_at": 2100000000,
              "last_usage": {
                "plan_type": "go",
                "primary": {
                  "used_percent": 5,
                  "window_minutes": null,
                  "resets_at": 2100000300
                },
                "secondary": {
                  "used_percent": 25,
                  "window_minutes": 10080,
                  "resets_at": 2100600000
                }
              }
            }
          ]
        }
        """#

        let registry = try JSONDecoder().decode(
            AccountRegistry.self,
            from: Data(json.utf8)
        )

        XCTAssertEqual(registry.accounts.first?.usageMeters.map(\.label), ["7d"])
        XCTAssertEqual(registry.accounts.first?.usageMeters.map(\.remainingPercent), [75])
    }

    // 재설정 시각이 지난 창은 완전히 회복된 상태이며 과거 시각을 노출하지 않는다.
    func testExpiredUsageWindowShowsFullRemainingWithoutResetDate() throws {
        let window = UsageWindow(
            usedPercent: 78,
            windowMinutes: 300,
            resetsAt: 100
        )

        let meter = try XCTUnwrap(
            UsageMeter(window: window, now: Date(timeIntervalSince1970: 200))
        )

        XCTAssertEqual(meter.remainingPercent, 100)
        XCTAssertNil(meter.resetsAt)
    }

    // 정확한 reset timestamp를 일·시간·분 단위의 짧은 카운트다운으로 표시한다.
    func testResetCountdownUsesCompactUnits() throws {
        let resetDate = Date(timeIntervalSince1970: 2_000_000)
        let window = UsageWindow(
            usedPercent: 41,
            windowMinutes: 10_080,
            resetsAt: Int64(resetDate.timeIntervalSince1970)
        )
        let meter = try XCTUnwrap(
            UsageMeter(
                window: window,
                now: resetDate.addingTimeInterval(-(6 * 86_400 + 18 * 3_600))
            )
        )

        XCTAssertEqual(
            meter.resetCountdown(at: resetDate.addingTimeInterval(-(6 * 86_400 + 18 * 3_600))),
            "6d 18h"
        )
        XCTAssertEqual(
            meter.resetCountdown(at: resetDate.addingTimeInterval(-(4 * 3_600 + 12 * 60))),
            "4h 12m"
        )
        XCTAssertEqual(meter.resetCountdown(at: resetDate.addingTimeInterval(-(42 * 60))), "42m")
        XCTAssertEqual(meter.resetCountdown(at: resetDate.addingTimeInterval(-30)), "<1m")
        XCTAssertEqual(meter.resetCountdown(at: resetDate.addingTimeInterval(1)), "0m")
    }

    // 기존 문구를 유지하면서 실제 조회 완료 시각을 기준으로 분·시간을 계산한다.
    func testAccountRefreshStatusAdvancesAtMinuteAndHourBoundaries() {
        let refreshedAt = Date(timeIntervalSince1970: 2_000_000)

        XCTAssertEqual(
            AccountRefreshStatus.text(
                since: refreshedAt,
                now: refreshedAt.addingTimeInterval(59)
            ),
            "방금 갱신"
        )
        XCTAssertEqual(
            AccountRefreshStatus.text(
                since: refreshedAt,
                now: refreshedAt.addingTimeInterval(60)
            ),
            "갱신 1분 전"
        )
        XCTAssertEqual(
            AccountRefreshStatus.text(
                since: refreshedAt,
                now: refreshedAt.addingTimeInterval(3_599)
            ),
            "갱신 59분 전"
        )
        XCTAssertEqual(
            AccountRefreshStatus.text(
                since: refreshedAt,
                now: refreshedAt.addingTimeInterval(3_600)
            ),
            "갱신 1시간 전"
        )
    }
}
