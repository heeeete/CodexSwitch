import Darwin
import Foundation
import XCTest
@testable import CodexSwitch

@MainActor
final class AccountStoreTests: XCTestCase {
    // 메뉴의 SwiftUI task가 취소돼도 첫 로드는 끝나며 다음 열기에서 중복 실행하지 않는다.
    func testInitialLoadOutlivesCancelledViewTask() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchStoreLoad-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let accountsURL = rootURL.appendingPathComponent("accounts", isDirectory: true)
        try FileManager.default.createDirectory(at: accountsURL, withIntermediateDirectories: true)
        try Data(
            #"{"schema_version":3,"active_account_key":null,"api":{"usage":false,"account":false},"accounts":[]}"#.utf8
        ).write(to: accountsURL.appendingPathComponent("registry.json"))

        let helperURL = rootURL.appendingPathComponent("codex-auth")
        let startedURL = rootURL.appendingPathComponent("started")
        let releaseURL = rootURL.appendingPathComponent("release")
        let countURL = rootURL.appendingPathComponent("count")
        let script = """
        #!/bin/sh
        /bin/echo x >> "$CODEXSWITCH_COUNT_FILE"
        /usr/bin/touch "$CODEXSWITCH_STARTED_FILE"
        while test ! -f "$CODEXSWITCH_RELEASE_FILE"; do
            /bin/sleep 0.05
        done
        """
        try Data(script.utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )

        let service = CodexAuthService(
            registryURL: accountsURL.appendingPathComponent("registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_SWITCH_HELPER_EXECUTABLE": helperURL.path,
                "CODEXSWITCH_STARTED_FILE": startedURL.path,
                "CODEXSWITCH_RELEASE_FILE": releaseURL.path,
                "CODEXSWITCH_COUNT_FILE": countURL.path
            ]
        )
        let store = AccountStore(authService: service)
        let viewTask = Task { await store.loadLocalAccounts() }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: startedURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.isLoading)
        viewTask.cancel()
        try Data().write(to: releaseURL)
        await viewTask.value

        XCTAssertFalse(store.isLoading)
        await store.loadLocalAccounts()
        let invocationCount = try String(contentsOf: countURL, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .count
        XCTAssertEqual(invocationCount, 1)
    }

    // 새로 고침 취소가 helper 트리를 끝내고 UI busy 상태를 반드시 해제한다.
    func testCancelRefreshClearsBusyStateAndKillsHelper() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchStoreCancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let helperURL = rootURL.appendingPathComponent("codex-auth")
        let pidURL = rootURL.appendingPathComponent("helper.pid")
        let script = """
        #!/bin/sh
        trap '' TERM
        /bin/echo "$$" > "$CODEXSWITCH_PID_FILE"
        while :; do
            /bin/sleep 1
        done
        """
        try Data(script.utf8).write(to: helperURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: helperURL.path
        )

        let previousPreference = UserDefaults.standard.object(forKey: "directAPIRefreshEnabled")
        defer {
            if let previousPreference {
                UserDefaults.standard.set(previousPreference, forKey: "directAPIRefreshEnabled")
            } else {
                UserDefaults.standard.removeObject(forKey: "directAPIRefreshEnabled")
            }
        }
        UserDefaults.standard.set(false, forKey: "directAPIRefreshEnabled")

        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_SWITCH_HELPER_EXECUTABLE": helperURL.path,
                "CODEXSWITCH_PID_FILE": pidURL.path
            ]
        )
        let store = AccountStore(authService: service)

        store.refresh()
        for _ in 0..<100 where !FileManager.default.fileExists(atPath: pidURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(store.isRefreshing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pidURL.path))

        store.cancelRefresh()
        for _ in 0..<150 where store.isRefreshing {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.isRefreshing)

        let helperPID = pid_t(
            try String(contentsOf: pidURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        )!
        XCTAssertNotEqual(Darwin.kill(helperPID, 0), 0)
    }
}
