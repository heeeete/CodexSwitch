import Darwin
import Foundation
import XCTest
@testable import CodexSwitch

@_silgen_name("flock")
private func testFlock(_ fileDescriptor: Int32, _ operation: Int32) -> Int32

final class CodexAuthServiceTests: XCTestCase {
    // 격리 로그인은 계정을 등록하되 첫 계정을 자동 활성화하거나 live auth를 만들지 않는다.
    func testConnectAccountUsesBundledHelperAndInjectedCodexCLI() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchConnect-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        let codexURL = binURL.appendingPathComponent("codex")
        try FileManager.default.copyItem(
            at: projectRootURL().appendingPathComponent("Tests/Fixtures/fake-codex"),
            to: codexURL
        )
        let authFixtureURL = projectRootURL()
            .appendingPathComponent("Tests/Fixtures/fake-auth.json")

        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEXSWITCH_FAKE_AUTH": authFixtureURL.path,
                "CODEX_SWITCH_HELPER_EXECUTABLE": bundledHelperURL().path,
                "CODEX_SWITCH_CODEX_EXECUTABLE": codexURL.path
            ]
        )

        let connectedAccountKey = try await service.connectAccount()
        let registry = try await service.loadRegistry()

        XCTAssertEqual(registry.accounts.map(\.email), ["user@example.com"])
        XCTAssertEqual(connectedAccountKey, registry.accounts.first?.accountKey)
        XCTAssertNil(registry.activeAccountKey)
        // 앱은 upstream의 전역 API 기본값을 로그인 과정에서 덮어쓰지 않는다.
        XCTAssertEqual(registry.api?.usage, true)
        XCTAssertEqual(registry.api?.account, true)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: rootURL.appendingPathComponent("auth.json").path
        ))
        let snapshotURL = rootURL
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(encodedSnapshotName(accountKey: connectedAccountKey))
        XCTAssertEqual(
            try Data(contentsOf: snapshotURL),
            try Data(contentsOf: authFixtureURL)
        )

        // 같은 계정을 다시 추가해도 기존 registry와 스냅샷을 덮어쓰지 않는다.
        let registryBeforeDuplicate = try Data(
            contentsOf: rootURL.appendingPathComponent("accounts/registry.json")
        )
        let snapshotBeforeDuplicate = try Data(contentsOf: snapshotURL)
        do {
            _ = try await service.connectAccount()
            XCTFail("이미 추가된 계정을 중복 등록하면 안 됩니다.")
        } catch CodexAuthError.accountAlreadyConnected {
            XCTAssertEqual(
                try Data(contentsOf: rootURL.appendingPathComponent("accounts/registry.json")),
                registryBeforeDuplicate
            )
            XCTAssertEqual(try Data(contentsOf: snapshotURL), snapshotBeforeDuplicate)
        }
    }

    // 기존 codex-auth 사용자가 정한 혼합 API 설정은 앱 로그인 뒤에도 그대로 남는다.
    func testConnectAccountDoesNotOverwriteExistingAPIConfiguration() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchExistingAPI-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let accountsURL = rootURL.appendingPathComponent("accounts", isDirectory: true)
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: accountsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)
        try Data(
            #"{"schema_version":3,"active_account_key":null,"api":{"usage":false,"account":true},"accounts":[]}"#.utf8
        ).write(to: accountsURL.appendingPathComponent("registry.json"))

        let codexURL = binURL.appendingPathComponent("codex")
        try FileManager.default.copyItem(
            at: projectRootURL().appendingPathComponent("Tests/Fixtures/fake-codex"),
            to: codexURL
        )
        let authFixtureURL = projectRootURL()
            .appendingPathComponent("Tests/Fixtures/fake-auth.json")
        let service = CodexAuthService(
            registryURL: accountsURL.appendingPathComponent("registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEXSWITCH_FAKE_AUTH": authFixtureURL.path,
                "CODEX_SWITCH_HELPER_EXECUTABLE": bundledHelperURL().path,
                "CODEX_SWITCH_CODEX_EXECUTABLE": codexURL.path
            ]
        )

        _ = try await service.connectAccount()
        let registry = try await service.loadRegistry()
        XCTAssertNil(registry.activeAccountKey)
        XCTAssertEqual(registry.api?.usage, false)
        XCTAssertEqual(registry.api?.account, true)
    }

    // 기존 활성 계정이 있으면 새 계정만 추가하고 live auth와 활성 키를 그대로 보존한다.
    func testConnectAccountPreservesExistingActiveCredential() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchPreserveActive-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let accountsURL = rootURL.appendingPathComponent("accounts", isDirectory: true)
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        let registryURL = accountsURL.appendingPathComponent("registry.json")
        let authURL = rootURL.appendingPathComponent("auth.json")
        try FileManager.default.createDirectory(at: accountsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let currentAccountKey = "current-user::current-account"
        let currentAuth = try makeAuthData(
            marker: "current",
            email: "current@example.com",
            userID: "current-user",
            accountID: "current-account",
            plan: "plus"
        )
        let currentSnapshotURL = accountsURL.appendingPathComponent(
            encodedSnapshotName(accountKey: currentAccountKey)
        )
        try currentAuth.write(to: authURL)
        try currentAuth.write(to: currentSnapshotURL)
        let registryRoot: [String: Any] = [
            "schema_version": 3,
            "active_account_key": currentAccountKey,
            "active_account_activated_at_ms": 1_234,
            "api": ["usage": false, "account": true],
            "accounts": [[
                "account_key": currentAccountKey,
                "chatgpt_account_id": "current-account",
                "chatgpt_user_id": "current-user",
                "email": "current@example.com",
                "alias": "Current",
                "plan": "plus",
                "auth_mode": "chatgpt",
                "created_at": 1,
                "last_used_at": 1
            ]]
        ]
        try JSONSerialization.data(withJSONObject: registryRoot, options: [.prettyPrinted])
            .write(to: registryURL)

        let newAuth = try makeAuthData(
            marker: "new",
            email: "new@example.com",
            userID: "new-user",
            accountID: "new-account",
            plan: "pro"
        )
        let newAuthURL = rootURL.appendingPathComponent("new-auth.json")
        try newAuth.write(to: newAuthURL)
        let codexURL = binURL.appendingPathComponent("codex")
        try FileManager.default.copyItem(
            at: projectRootURL().appendingPathComponent("Tests/Fixtures/fake-codex"),
            to: codexURL
        )

        let service = CodexAuthService(
            registryURL: registryURL,
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEXSWITCH_FAKE_AUTH": newAuthURL.path,
                "CODEX_SWITCH_HELPER_EXECUTABLE": bundledHelperURL().path,
                "CODEX_SWITCH_CODEX_EXECUTABLE": codexURL.path
            ]
        )

        let connectedAccountKey = try await service.connectAccount()
        let registry = try await service.loadRegistry()
        XCTAssertEqual(connectedAccountKey, "new-user::new-account")
        XCTAssertEqual(registry.activeAccountKey, currentAccountKey)
        XCTAssertEqual(Set(registry.accounts.map(\.accountKey)), [currentAccountKey, connectedAccountKey])
        XCTAssertEqual(registry.api?.usage, false)
        XCTAssertEqual(registry.api?.account, true)
        XCTAssertEqual(try Data(contentsOf: authURL), currentAuth)
        XCTAssertEqual(try Data(contentsOf: currentSnapshotURL), currentAuth)
        XCTAssertEqual(
            try Data(contentsOf: accountsURL.appendingPathComponent(
                encodedSnapshotName(accountKey: connectedAccountKey)
            )),
            newAuth
        )

        // 활성 계정의 선택 시각도 import 과정에서 갱신되지 않아야 한다.
        let updatedRoot = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: registryURL)) as? [String: Any]
        )
        XCTAssertEqual((updatedRoot["active_account_activated_at_ms"] as? NSNumber)?.intValue, 1_234)
    }

    // 팀 계정 로그인도 전역 API 설정은 보존하면서 선택적 메타데이터 네트워크를 실행하지 않는다.
    func testConnectTeamAccountDoesNotUseConfiguredNode() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchTeamLogin-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let authURL = rootURL.appendingPathComponent("team-auth.json")
        try makeAuthData(
            marker: "team",
            email: "team@example.com",
            userID: "team-user",
            accountID: "team-account",
            plan: "team"
        ).write(to: authURL)
        let codexURL = binURL.appendingPathComponent("codex")
        try FileManager.default.copyItem(
            at: projectRootURL().appendingPathComponent("Tests/Fixtures/fake-codex"),
            to: codexURL
        )

        let nodeURL = binURL.appendingPathComponent("node")
        let nodeMarkerURL = rootURL.appendingPathComponent("node-called")
        try makeExecutableScript(
            "#!/bin/sh\n/bin/touch \"$CODEXSWITCH_NODE_MARKER\"\nexit 1\n",
            at: nodeURL
        )
        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEXSWITCH_FAKE_AUTH": authURL.path,
                "CODEXSWITCH_NODE_MARKER": nodeMarkerURL.path,
                "CODEX_AUTH_NODE_EXECUTABLE": nodeURL.path,
                "CODEX_SWITCH_HELPER_EXECUTABLE": bundledHelperURL().path,
                "CODEX_SWITCH_CODEX_EXECUTABLE": codexURL.path
            ]
        )

        _ = try await service.connectAccount()
        let registry = try await service.loadRegistry()
        XCTAssertEqual(registry.accounts.map(\.email), ["team@example.com"])
        XCTAssertNil(registry.activeAccountKey)
        XCTAssertEqual(registry.api?.account, true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: nodeMarkerURL.path))
    }

    // 로그인 실행기가 없으면 서비스가 만든 문구가 아니라 helper 원문을 전달한다.
    func testMissingLoginRuntimePreservesBundledHelperError() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchMissingCLI-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_SWITCH_HELPER_EXECUTABLE": bundledHelperURL().path,
                "CODEX_SWITCH_DISABLE_USER_EXECUTABLES": "1",
                "CODEX_SWITCH_DISABLE_CHATGPT_RUNTIME": "1"
            ]
        )

        do {
            try await service.connectAccount()
            XCTFail("Codex 실행기가 없으면 helper login이 실패해야 합니다.")
        } catch CodexAuthError.commandFailed(let message) {
            XCTAssertTrue(message.contains("`codex` executable was not found"), message)
            XCTAssertTrue(message.contains("Ensure the Codex CLI is installed"), message)
        }
    }

    // 취소된 첫 연결이 만든 빈 registry 뒤에 생긴 auth도 다음 시작에서 가져온다.
    func testStartupReconcilesAuthIntoExistingEmptyRegistry() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchStartup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let registryURL = rootURL.appendingPathComponent("accounts/registry.json")
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(
            #"{"schema_version":3,"active_account_key":null,"api":{"usage":false,"account":false},"accounts":[]}"#.utf8
        ).write(to: registryURL)
        try makeAuthData(
            marker: "late-auth",
            email: "late@example.com",
            userID: "late-user",
            accountID: "late-account",
            plan: "plus"
        ).write(to: rootURL.appendingPathComponent("auth.json"))

        let service = CodexAuthService(
            registryURL: registryURL,
            environment: ["HOME": rootURL.path, "CODEX_HOME": rootURL.path]
        )
        let registry = try await service.loadOrImportLocalRegistry()

        XCTAssertEqual(registry.accounts.map(\.email), ["late@example.com"])
        XCTAssertEqual(registry.activeAccountKey, "late-user::late-account")
    }

    // 앱 시작 시 stable helper가 지원하는 v2 registry를 v3로 먼저 마이그레이션한다.
    func testStartupMigratesLegacyRegistryBeforeDecoding() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchMigration-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let accountsURL = rootURL.appendingPathComponent("accounts", isDirectory: true)
        let registryURL = accountsURL.appendingPathComponent("registry.json")
        try FileManager.default.createDirectory(at: accountsURL, withIntermediateDirectories: true)
        try Data(
            #"{"schema_version":2,"active_email":"legacy@example.com","accounts":[{"email":"legacy@example.com","alias":"","plan":"plus","created_at":1}]}"#.utf8
        ).write(to: registryURL)
        let legacyAuth = try makeAuthData(
            marker: "legacy",
            email: "legacy@example.com",
            userID: "legacy-user",
            accountID: "legacy-account",
            plan: "plus"
        )
        try legacyAuth.write(
            to: accountsURL.appendingPathComponent(
                encodedSnapshotName(accountKey: "legacy@example.com")
            )
        )
        try legacyAuth.write(to: rootURL.appendingPathComponent("auth.json"))

        let service = CodexAuthService(
            registryURL: registryURL,
            environment: ["HOME": rootURL.path, "CODEX_HOME": rootURL.path]
        )
        let registry = try await service.loadOrImportLocalRegistry()

        XCTAssertEqual(registry.schemaVersion, 3)
        XCTAssertEqual(registry.activeAccountKey, "legacy-user::legacy-account")
        XCTAssertEqual(registry.accounts.first?.email, "legacy@example.com")
    }

    // 실제 bundled helper 로그인 취소 시 하위 Codex 프로세스도 남기지 않는다.
    func testCancelledLoginTerminatesHelperProcessTree() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchCancel-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let codexURL = rootURL.appendingPathComponent("codex")
        let childPIDURL = rootURL.appendingPathComponent("child.pid")
        let script = """
        #!/bin/sh
        test "$1" = "login"
        trap '' TERM
        /bin/echo "$$" > "$CODEXSWITCH_PID_FILE"
        while :; do
            /bin/sleep 1
        done
        """
        try Data(script.utf8).write(to: codexURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: codexURL.path
        )

        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEXSWITCH_PID_FILE": childPIDURL.path,
                "CODEX_SWITCH_HELPER_EXECUTABLE": bundledHelperURL().path,
                "CODEX_SWITCH_CODEX_EXECUTABLE": codexURL.path
            ]
        )
        let loginTask = Task { try await service.connectAccount() }

        guard let childPID = try await waitForPID(at: childPIDURL) else {
            loginTask.cancel()
            XCTFail("하위 Codex PID가 기록되지 않았습니다.")
            return
        }

        loginTask.cancel()
        do {
            _ = try await loginTask.value
            XCTFail("취소한 로그인은 성공하면 안 됩니다.")
        } catch is CancellationError {
            // 의도한 취소 경로다.
        }

        for _ in 0..<100 where Darwin.kill(childPID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(Darwin.kill(childPID, 0), 0)
    }

    // 격리 login 취소가 파일 쓰기와 겹쳐도 실제 auth와 registry에는 닿지 않는다.
    func testCancelledLoginDoesNotTouchRealCredentialFilesAfterPartialWrite() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchLoginRestore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let accountsURL = rootURL.appendingPathComponent("accounts", isDirectory: true)
        try FileManager.default.createDirectory(at: accountsURL, withIntermediateDirectories: true)
        let authURL = rootURL.appendingPathComponent("auth.json")
        let registryURL = accountsURL.appendingPathComponent("registry.json")
        let originalAuth = try makeAuthData(
            marker: "original",
            email: "original@example.com",
            userID: "original-user",
            accountID: "original-account",
            plan: "plus"
        )
        let originalRegistry = Data(
            #"{"schema_version":3,"active_account_key":null,"api":{"usage":false,"account":false},"accounts":[]}"#.utf8
        )
        try originalAuth.write(to: authURL)
        try originalRegistry.write(to: registryURL)

        let helperURL = rootURL.appendingPathComponent("codex-auth")
        let writeMarkerURL = rootURL.appendingPathComponent("partial-write-complete")
        try makeExecutableScript(
            """
            #!/bin/sh
            trap '' TERM
            /bin/echo partial-auth > "$CODEX_HOME/auth.json"
            /bin/echo partial-registry > "$CODEX_HOME/accounts/registry.json"
            /usr/bin/touch "$CODEXSWITCH_WRITE_MARKER"
            while :; do
                /bin/sleep 1
            done
            """,
            at: helperURL
        )
        let service = CodexAuthService(
            registryURL: registryURL,
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_SWITCH_HELPER_EXECUTABLE": helperURL.path,
                "CODEX_SWITCH_CODEX_EXECUTABLE": "/usr/bin/true",
                "CODEXSWITCH_WRITE_MARKER": writeMarkerURL.path
            ]
        )
        let loginTask = Task { try await service.connectAccount() }

        for _ in 0..<100 where !FileManager.default.fileExists(atPath: writeMarkerURL.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: writeMarkerURL.path))
        loginTask.cancel()
        do {
            _ = try await loginTask.value
            XCTFail("부분 쓰기 뒤 취소된 login은 성공하면 안 됩니다.")
        } catch is CancellationError {
            XCTAssertEqual(try Data(contentsOf: authURL), originalAuth)
            XCTAssertEqual(try Data(contentsOf: registryURL), originalRegistry)
        }
    }

    // 취소 도중 helper가 새 자식을 만들어도 두 번째 수집에서 찾아 함께 종료한다.
    func testCancellationKillsChildCreatedAfterInitialTermination() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchLateChild-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let helperURL = rootURL.appendingPathComponent("codex-auth")
        let initialPIDURL = rootURL.appendingPathComponent("initial.pid")
        let latePIDURL = rootURL.appendingPathComponent("late.pid")
        try makeExecutableScript(
            """
            #!/bin/sh
            trap 'exit 0' TERM
            /bin/sleep 60 &
            initial_pid=$!
            /bin/echo "$initial_pid" > "$CODEXSWITCH_INITIAL_PID_FILE"
            while /bin/kill -0 "$initial_pid" 2>/dev/null; do
                /bin/sleep 0.02
            done
            /bin/sh -c 'trap "" TERM; /bin/echo "$$" > "$CODEXSWITCH_LATE_PID_FILE"; while :; do /bin/sleep 1; done' &
            while :; do
                /bin/sleep 1
            done
            """,
            at: helperURL
        )
        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_SWITCH_HELPER_EXECUTABLE": helperURL.path,
                "CODEXSWITCH_INITIAL_PID_FILE": initialPIDURL.path,
                "CODEXSWITCH_LATE_PID_FILE": latePIDURL.path
            ]
        )
        let refreshTask = Task { try await service.refreshAccounts(useDirectAPI: false) }
        guard try await waitForPID(at: initialPIDURL) != nil else {
            refreshTask.cancel()
            XCTFail("최초 helper 자식 PID가 기록되지 않았습니다.")
            return
        }

        refreshTask.cancel()
        do {
            try await refreshTask.value
            XCTFail("취소한 새로 고침은 성공하면 안 됩니다.")
        } catch is CancellationError {
            // 의도한 취소 경로다.
        }

        guard let latePID = try await waitForPID(at: latePIDURL) else {
            XCTFail("종료 단계에서 만들어진 자식 PID가 기록되지 않았습니다.")
            return
        }
        defer {
            if Darwin.kill(latePID, 0) == 0 {
                _ = Darwin.kill(latePID, SIGKILL)
            }
        }
        for _ in 0..<100 where Darwin.kill(latePID, 0) == 0 {
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertNotEqual(Darwin.kill(latePID, 0), 0)
    }

    // 모든 helper 호출은 앱이 소유하지 않은 upstream 자동 전환 서비스를 건드리지 않는다.
    func testHelperEnvironmentSkipsServiceReconcileAndUsesPATHNode() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchEnvironment-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let binURL = rootURL.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binURL, withIntermediateDirectories: true)

        let nodeURL = binURL.appendingPathComponent("node")
        try makeExecutableScript("#!/bin/sh\nexit 0\n", at: nodeURL)
        let helperURL = rootURL.appendingPathComponent("codex-auth")
        let argumentsURL = rootURL.appendingPathComponent("arguments.txt")
        let serviceFlagURL = rootURL.appendingPathComponent("service-flag.txt")
        let nodePathURL = rootURL.appendingPathComponent("node-path.txt")
        try makeExecutableScript(
            """
            #!/bin/sh
            /bin/echo "$*" > "$CODEXSWITCH_ARGUMENTS_FILE"
            /bin/echo "$CODEX_AUTH_SKIP_SERVICE_RECONCILE" > "$CODEXSWITCH_SERVICE_FLAG_FILE"
            /bin/echo "$CODEX_AUTH_NODE_EXECUTABLE" > "$CODEXSWITCH_NODE_PATH_FILE"
            """,
            at: helperURL
        )

        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "\(binURL.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_SWITCH_HELPER_EXECUTABLE": helperURL.path,
                "CODEXSWITCH_ARGUMENTS_FILE": argumentsURL.path,
                "CODEXSWITCH_SERVICE_FLAG_FILE": serviceFlagURL.path,
                "CODEXSWITCH_NODE_PATH_FILE": nodePathURL.path
            ]
        )

        try await service.refreshAccounts(useDirectAPI: true)

        XCTAssertEqual(try readTrimmed(argumentsURL), "list --api")
        XCTAssertEqual(try readTrimmed(serviceFlagURL), "1")
        XCTAssertEqual(try readTrimmed(nodePathURL), nodeURL.path)
    }

    // codex-auth가 공식 지원하는 Node override는 앱이 삭제하거나 다른 Node로 바꾸지 않는다.
    func testDirectAPIRefreshPreservesCodexAuthNodeOverride() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchNodeOverride-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let nodeURL = rootURL.appendingPathComponent("custom-node")
        try makeExecutableScript("#!/bin/sh\nexit 0\n", at: nodeURL)
        let helperURL = rootURL.appendingPathComponent("codex-auth")
        let nodePathURL = rootURL.appendingPathComponent("node-path.txt")
        try makeExecutableScript(
            "#!/bin/sh\n/bin/echo \"$CODEX_AUTH_NODE_EXECUTABLE\" > \"$CODEXSWITCH_NODE_PATH_FILE\"\n",
            at: helperURL
        )

        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_AUTH_NODE_EXECUTABLE": nodeURL.path,
                "CODEX_SWITCH_HELPER_EXECUTABLE": helperURL.path,
                "CODEXSWITCH_NODE_PATH_FILE": nodePathURL.path
            ]
        )

        try await service.refreshAccounts(useDirectAPI: true)
        XCTAssertEqual(try readTrimmed(nodePathURL), nodeURL.path)
    }

    // 비대화식 helper가 SIGTERM을 무시해도 제한시간 뒤 강제 종료하고 busy 상태를 풀 수 있다.
    func testNonInteractiveCommandTimesOutAndKillsHelper() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchTimeout-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let helperURL = rootURL.appendingPathComponent("codex-auth")
        let pidURL = rootURL.appendingPathComponent("helper.pid")
        try makeExecutableScript(
            """
            #!/bin/sh
            trap '' TERM
            /bin/echo "$$" > "$CODEXSWITCH_PID_FILE"
            while :; do
                /bin/sleep 1
            done
            """,
            at: helperURL
        )
        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_SWITCH_HELPER_EXECUTABLE": helperURL.path,
                "CODEXSWITCH_PID_FILE": pidURL.path
            ],
            standardCommandTimeout: 0.5
        )

        let startedAt = Date()
        do {
            try await service.refreshAccounts(useDirectAPI: false)
            XCTFail("응답 없는 helper는 성공하면 안 됩니다.")
        } catch CodexAuthError.commandTimedOut {
            XCTAssertLessThan(Date().timeIntervalSince(startedAt), 3)
        }

        let helperPID = pid_t(try readTrimmed(pidURL))!
        XCTAssertNotEqual(Darwin.kill(helperPID, 0), 0)
    }

    // 실패 시 stderr와 stdout의 진단을 모두 보존한다.
    func testCommandFailurePreservesBothOutputStreams() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchOutput-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let helperURL = rootURL.appendingPathComponent("codex-auth")
        try makeExecutableScript(
            "#!/bin/sh\n/bin/echo stdout-detail\n/bin/echo stderr-detail >&2\nexit 1\n",
            at: helperURL
        )
        let service = CodexAuthService(
            registryURL: rootURL.appendingPathComponent("accounts/registry.json"),
            environment: [
                "HOME": rootURL.path,
                "CODEX_HOME": rootURL.path,
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "CODEX_SWITCH_HELPER_EXECUTABLE": helperURL.path
            ]
        )

        do {
            try await service.refreshAccounts(useDirectAPI: false)
            XCTFail("실패한 helper 명령은 성공하면 안 됩니다.")
        } catch CodexAuthError.commandFailed(let message) {
            XCTAssertTrue(message.contains("stderr-detail"), message)
            XCTAssertTrue(message.contains("stdout-detail"), message)
        }
    }

    // account_key에 파일명 특수 문자가 있어도 정확한 스냅샷만 원자적으로 적용한다.
    func testSwitchUsesExactAccountKeySnapshot() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }

        let service = CodexAuthService(
            registryURL: fixture.registryURL,
            environment: [
                "HOME": fixture.codexHomeURL.path,
                "CODEX_HOME": fixture.codexHomeURL.path
            ]
        )
        try await service.switchAccount(accountKey: fixture.targetAccountKey)

        let activeAuth = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.authURL)
        ) as? [String: Any]
        XCTAssertEqual(activeAuth?["marker"] as? String, "target")

        let registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.registryURL)
        ) as? [String: Any]
        XCTAssertEqual(registry?["active_account_key"] as? String, fixture.targetAccountKey)
        let accounts = registry?["accounts"] as? [[String: Any]]
        let target = accounts?.first { $0["account_key"] as? String == fixture.targetAccountKey }
        XCTAssertNotNil(target?["last_used_at"])

        // 전환 직전 live auth가 현재 계정의 스냅샷으로 동기화돼야 한다.
        let currentSnapshotName = encodedSnapshotName(accountKey: "current-user::current-account")
        let currentSnapshot = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.accountsURL.appendingPathComponent(currentSnapshotName))
        ) as? [String: Any]
        XCTAssertEqual(currentSnapshot?["marker"] as? String, "original")

        let backupNames = try FileManager.default.contentsOfDirectory(
            atPath: fixture.accountsURL.path
        )
        XCTAssertTrue(backupNames.contains { $0.hasPrefix("auth.json.bak.") })
        XCTAssertTrue(backupNames.contains { $0.hasPrefix("registry.json.bak.") })

        let permissions = try FileManager.default.attributesOfItem(
            atPath: fixture.authURL.path
        )[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    // 존재하지 않는 account_key는 현재 인증 파일을 변경하지 않는다.
    func testMissingAccountDoesNotChangeActiveAuth() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }
        let originalAuth = try Data(contentsOf: fixture.authURL)

        let service = CodexAuthService(
            registryURL: fixture.registryURL,
            environment: [
                "HOME": fixture.codexHomeURL.path,
                "CODEX_HOME": fixture.codexHomeURL.path
            ]
        )

        do {
            try await service.switchAccount(accountKey: "missing-account")
            XCTFail("없는 계정 전환은 실패해야 합니다.")
        } catch CodexAuthError.accountNotFound {
            XCTAssertEqual(try Data(contentsOf: fixture.authURL), originalAuth)
        }
    }

    // upstream auto daemon이 lock을 보유하면 수동 전환으로 인증 파일을 덮어쓰지 않는다.
    func testSwitchRefusesWhileAutoSwitchDaemonLockIsHeld() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }
        let originalAuth = try Data(contentsOf: fixture.authURL)
        let lockURL = fixture.accountsURL.appendingPathComponent("auto-switch.lock")
        let descriptor = lockURL.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        }
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        guard descriptor >= 0 else { return }
        XCTAssertEqual(testFlock(descriptor, LOCK_EX | LOCK_NB), 0)
        defer {
            _ = testFlock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }

        let service = CodexAuthService(
            registryURL: fixture.registryURL,
            environment: [
                "HOME": fixture.codexHomeURL.path,
                "CODEX_HOME": fixture.codexHomeURL.path
            ]
        )
        do {
            try await service.switchAccount(accountKey: fixture.targetAccountKey)
            XCTFail("auto daemon lock 중에는 수동 전환하면 안 됩니다.")
        } catch CodexAuthError.autoSwitchRunning {
            XCTAssertEqual(try Data(contentsOf: fixture.authURL), originalAuth)
        }
    }

    // 이메일이 같아도 선택한 account_key의 비활성 계정 하나만 제거한다.
    func testRemoveUsesExactAccountKeyForDuplicateEmail() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }

        var registry = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.registryURL))
                as? [String: Any]
        )
        var accounts = try XCTUnwrap(registry["accounts"] as? [[String: Any]])
        accounts[1]["email"] = accounts[0]["email"]
        registry["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: registry, options: [.prettyPrinted])
            .write(to: fixture.registryURL)

        let removedBackupURL = fixture.accountsURL.appendingPathComponent("auth.json.bak.removed")
        try makeAuthData(
            marker: "removed-backup",
            email: "current@example.com",
            userID: "chatgpt",
            accountID: "target/user",
            plan: "pro"
        ).write(to: removedBackupURL)

        let service = makeService(for: fixture)
        _ = try await service.removeAccount(
            accountKey: fixture.targetAccountKey,
            expectedActive: false
        )

        let activeAuth = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.authURL)
        ) as? [String: Any]
        XCTAssertEqual(activeAuth?["marker"] as? String, "original")

        let updatedRegistry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.registryURL)
        ) as? [String: Any]
        let remainingAccounts = updatedRegistry?["accounts"] as? [[String: Any]]
        XCTAssertEqual(remainingAccounts?.count, 1)
        XCTAssertEqual(
            remainingAccounts?.first?["account_key"] as? String,
            fixture.currentAccountKey
        )
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.accountsURL
                .appendingPathComponent(encodedSnapshotName(accountKey: fixture.targetAccountKey))
                .path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedBackupURL.path))
    }

    // 알 수 없는 인증 백업을 확인하지 못하면 제거 성공과 별도로 정리 경고를 반환한다.
    func testRemoveReportsIncompleteCredentialCleanup() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }
        try Data(#"{"unknown":"credential-format"}"#.utf8).write(
            to: fixture.accountsURL.appendingPathComponent("auth.json.bak.unknown")
        )

        let result = try await makeService(for: fixture).removeAccount(
            accountKey: fixture.targetAccountKey,
            expectedActive: false
        )

        XCTAssertFalse(result.credentialCleanupComplete)
        let registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.registryURL)
        ) as? [String: Any]
        XCTAssertEqual((registry?["accounts"] as? [[String: Any]])?.count, 1)
    }

    // 활성 계정을 제거하면 남은 계정의 스냅샷을 적용하고 삭제 자격증명을 정리한다.
    func testRemoveActiveAccountAppliesRemainingAccount() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }
        let removedBackupURL = fixture.accountsURL.appendingPathComponent("auth.json.bak.current")
        try makeAuthData(
            marker: "old-current",
            email: "current@example.com",
            userID: "current-user",
            accountID: "current-account",
            plan: "plus"
        ).write(to: removedBackupURL)

        let service = makeService(for: fixture)
        _ = try await service.removeAccount(
            accountKey: fixture.currentAccountKey,
            expectedActive: true
        )

        let activeAuth = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.authURL)
        ) as? [String: Any]
        XCTAssertEqual(activeAuth?["marker"] as? String, "target")

        let registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.registryURL)
        ) as? [String: Any]
        XCTAssertEqual(registry?["active_account_key"] as? String, fixture.targetAccountKey)
        let accounts = registry?["accounts"] as? [[String: Any]]
        XCTAssertEqual(accounts?.count, 1)
        XCTAssertEqual(accounts?.first?["account_key"] as? String, fixture.targetAccountKey)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: fixture.accountsURL
                .appendingPathComponent(encodedSnapshotName(accountKey: fixture.currentAccountKey))
                .path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removedBackupURL.path))
    }

    // 남은 계정이 여러 개면 upstream과 같은 잔여 사용량 점수로 대체 계정을 고른다.
    func testRemoveActiveAccountChoosesBestRemainingUsage() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }
        let preferredAccountKey = "preferred-user::preferred-account"

        var registry = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.registryURL))
                as? [String: Any]
        )
        var accounts = try XCTUnwrap(registry["accounts"] as? [[String: Any]])
        accounts[1]["last_usage_at"] = 10
        accounts[1]["last_usage"] = [
            "primary": ["used_percent": 95, "window_minutes": 300],
            "secondary": ["used_percent": 95, "window_minutes": 10_080]
        ]
        accounts.append([
            "account_key": preferredAccountKey,
            "chatgpt_account_id": "preferred-account",
            "chatgpt_user_id": "preferred-user",
            "email": "preferred@example.com",
            "alias": "",
            "plan": "pro",
            "auth_mode": "chatgpt",
            "created_at": 1,
            "last_used_at": 1,
            "last_usage_at": 1,
            "last_usage": [
                "primary": ["used_percent": 10, "window_minutes": 300],
                "secondary": ["used_percent": 20, "window_minutes": 10_080]
            ]
        ])
        registry["accounts"] = accounts
        try JSONSerialization.data(withJSONObject: registry, options: [.prettyPrinted])
            .write(to: fixture.registryURL)
        try makeAuthData(
            marker: "preferred",
            email: "preferred@example.com",
            userID: "preferred-user",
            accountID: "preferred-account",
            plan: "pro"
        ).write(
            to: fixture.accountsURL.appendingPathComponent(
                encodedSnapshotName(accountKey: preferredAccountKey)
            )
        )

        let service = makeService(for: fixture)
        _ = try await service.removeAccount(
            accountKey: fixture.currentAccountKey,
            expectedActive: true
        )

        let activeAuth = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.authURL)
        ) as? [String: Any]
        XCTAssertEqual(activeAuth?["marker"] as? String, "preferred")
        let updatedRegistry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.registryURL)
        ) as? [String: Any]
        XCTAssertEqual(updatedRegistry?["active_account_key"] as? String, preferredAccountKey)
    }

    // 대체 계정 스냅샷이 없으면 제거 전에 중단하고 live auth와 registry를 보존한다.
    func testRemoveActiveAccountStopsBeforeMutationWhenReplacementSnapshotIsMissing() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }
        try FileManager.default.removeItem(
            at: fixture.accountsURL.appendingPathComponent(
                encodedSnapshotName(accountKey: fixture.targetAccountKey)
            )
        )
        let originalAuth = try Data(contentsOf: fixture.authURL)
        let service = makeService(for: fixture)

        do {
            _ = try await service.removeAccount(
                accountKey: fixture.currentAccountKey,
                expectedActive: true
            )
            XCTFail("대체 스냅샷 없이 활성 계정을 제거하면 안 됩니다.")
        } catch CodexAuthError.snapshotNotFound {
            XCTAssertEqual(try Data(contentsOf: fixture.authURL), originalAuth)
            let registry = try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.registryURL)
            ) as? [String: Any]
            XCTAssertEqual((registry?["accounts"] as? [[String: Any]])?.count, 2)
            XCTAssertEqual(
                registry?["active_account_key"] as? String,
                fixture.currentAccountKey
            )
        }
    }

    // 마지막 활성 계정을 제거하면 registry를 비우고 live auth도 해제한다.
    func testRemoveLastActiveAccountDeletesLiveAuth() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }
        let service = makeService(for: fixture)

        _ = try await service.removeAccount(
            accountKey: fixture.targetAccountKey,
            expectedActive: false
        )
        _ = try await service.removeAccount(
            accountKey: fixture.currentAccountKey,
            expectedActive: true
        )

        let registry = try JSONSerialization.jsonObject(
            with: Data(contentsOf: fixture.registryURL)
        ) as? [String: Any]
        XCTAssertTrue((registry?["accounts"] as? [[String: Any]])?.isEmpty == true)
        XCTAssertTrue(registry?["active_account_key"] is NSNull)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.authURL.path))
    }

    // 화면의 활성 상태가 stale이면 어떤 계정도 제거하지 않는다.
    func testRemoveRejectsStaleExpectedActiveState() async throws {
        let fixture = try makeSwitchFixture()
        defer { try? FileManager.default.removeItem(at: fixture.codexHomeURL) }
        let originalAuth = try Data(contentsOf: fixture.authURL)
        let service = makeService(for: fixture)

        do {
            _ = try await service.removeAccount(
                accountKey: fixture.targetAccountKey,
                expectedActive: true
            )
            XCTFail("stale 활성 상태로 계정을 제거하면 안 됩니다.")
        } catch CodexAuthError.registryChanged {
            XCTAssertEqual(try Data(contentsOf: fixture.authURL), originalAuth)
            let registry = try JSONSerialization.jsonObject(
                with: Data(contentsOf: fixture.registryURL)
            ) as? [String: Any]
            XCTAssertEqual((registry?["accounts"] as? [[String: Any]])?.count, 2)
        }
    }

    // CODEX_HOME 설정은 Finder 기본 홈과 분리된 registry 위치를 사용한다.
    func testRegistryURLUsesConfiguredCodexHome() {
        let url = CodexAuthService.defaultRegistryURL(
            environment: ["CODEX_HOME": "/tmp/codex-switch-test-home"]
        )
        XCTAssertEqual(
            url.path,
            "/tmp/codex-switch-test-home/accounts/registry.json"
        )
    }

    // 실제 시작·전환 경로도 helper 실행 전에 prerelease schema 4를 거부한다.
    func testSchemaFourRegistryIsRejectedWithoutMigration() async throws {
        let rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitchSchema4-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: rootURL) }
        let registryURL = rootURL.appendingPathComponent("accounts/registry.json")
        try FileManager.default.createDirectory(
            at: registryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(#"{"schema_version":4,"active_account_key":null,"accounts":[]}"#.utf8)
            .write(to: registryURL)

        let service = CodexAuthService(registryURL: registryURL, environment: [:])
        do {
            _ = try await service.loadOrImportLocalRegistry()
            XCTFail("schema 4는 자동 마이그레이션하지 않아야 합니다.")
        } catch CodexAuthError.unsupportedRegistryVersion(let version) {
            XCTAssertEqual(version, 4)
        }

        do {
            try await service.switchAccount(accountKey: "missing")
            XCTFail("전환 경로도 schema 4 helper 실행 전에 실패해야 합니다.")
        } catch CodexAuthError.unsupportedRegistryVersion(let version) {
            XCTAssertEqual(version, 4)
        }
    }

    private struct SwitchFixture {
        let codexHomeURL: URL
        let accountsURL: URL
        let registryURL: URL
        let authURL: URL
        let currentAccountKey: String
        let targetAccountKey: String
    }

    // 실제 stable registry와 같은 핵심 필드로 격리된 전환 환경을 만든다.
    private func makeSwitchFixture() throws -> SwitchFixture {
        let fileManager = FileManager.default
        let codexHomeURL = fileManager.temporaryDirectory
            .appendingPathComponent("CodexSwitchTests-\(UUID().uuidString)", isDirectory: true)
        let accountsURL = codexHomeURL.appendingPathComponent("accounts", isDirectory: true)
        let registryURL = accountsURL.appendingPathComponent("registry.json")
        let authURL = codexHomeURL.appendingPathComponent("auth.json")
        let targetAccountKey = "chatgpt::target/user"
        let currentAccountKey = "current-user::current-account"

        try fileManager.createDirectory(
            at: accountsURL,
            withIntermediateDirectories: true
        )
        let registry: [String: Any] = [
            "schema_version": 3,
            "active_account_key": currentAccountKey,
            "active_account_activated_at_ms": 1,
            "api": ["usage": false, "account": false],
            "accounts": [
                [
                    "account_key": currentAccountKey,
                    "chatgpt_account_id": "current-account",
                    "chatgpt_user_id": "current-user",
                    "email": "current@example.com",
                    "alias": "",
                    "plan": "plus",
                    "auth_mode": "chatgpt",
                    "created_at": 1,
                    "last_used_at": 1
                ],
                [
                    "account_key": targetAccountKey,
                    "chatgpt_account_id": "target/user",
                    "chatgpt_user_id": "chatgpt",
                    "email": "target@example.com",
                    "alias": "",
                    "plan": "pro",
                    "auth_mode": "chatgpt",
                    "created_at": 1,
                    "last_used_at": 1
                ]
            ]
        ]
        try JSONSerialization.data(
            withJSONObject: registry,
            options: [.prettyPrinted]
        ).write(to: registryURL)
        try makeAuthData(
            marker: "original",
            email: "current@example.com",
            userID: "current-user",
            accountID: "current-account",
            plan: "plus"
        ).write(to: authURL)

        let encodedKey = Data(targetAccountKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let snapshotURL = accountsURL.appendingPathComponent("\(encodedKey).auth.json")
        try makeAuthData(
            marker: "target",
            email: "target@example.com",
            userID: "chatgpt",
            accountID: "target/user",
            plan: "pro"
        ).write(to: snapshotURL)

        return SwitchFixture(
            codexHomeURL: codexHomeURL,
            accountsURL: accountsURL,
            registryURL: registryURL,
            authURL: authURL,
            currentAccountKey: currentAccountKey,
            targetAccountKey: targetAccountKey
        )
    }

    private func makeService(for fixture: SwitchFixture) -> CodexAuthService {
        CodexAuthService(
            registryURL: fixture.registryURL,
            environment: [
                "HOME": fixture.codexHomeURL.path,
                "CODEX_HOME": fixture.codexHomeURL.path
            ]
        )
    }

    // helper가 실제로 파싱할 수 있는 JWT 모양의 auth fixture를 만든다.
    private func makeAuthData(
        marker: String,
        email: String,
        userID: String,
        accountID: String,
        plan: String
    ) throws -> Data {
        let claims: [String: Any] = [
            "email": email,
            "https://api.openai.com/auth": [
                "chatgpt_account_id": accountID,
                "chatgpt_user_id": userID,
                "user_id": userID,
                "chatgpt_plan_type": plan
            ]
        ]
        let payload = try JSONSerialization.data(withJSONObject: claims)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let root: [String: Any] = [
            "marker": marker,
            "tokens": [
                "access_token": "access-\(marker)",
                "account_id": accountID,
                "id_token": "eyJhbGciOiJub25lIn0.\(payload).sig"
            ]
        ]
        return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func encodedSnapshotName(accountKey: String) -> String {
        let encoded = Data(accountKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(encoded).auth.json"
    }

    private func projectRootURL() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeExecutableScript(_ script: String, at url: URL) throws {
        try Data(script.utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: url.path
        )
    }

    private func readTrimmed(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // 셸이 파일을 만든 뒤 PID 내용을 쓰는 짧은 구간까지 기다린다.
    private func waitForPID(at url: URL) async throws -> pid_t? {
        for _ in 0..<100 {
            if let value = try? readTrimmed(url), let processID = pid_t(value) {
                return processID
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }

    private func bundledHelperURL() -> URL {
        #if arch(arm64)
        let platform = "darwin-arm64"
        #elseif arch(x86_64)
        let platform = "darwin-x86_64"
        #else
        let platform = "unsupported"
        #endif
        return projectRootURL()
            .appendingPathComponent("Vendor/codex-auth/bin/\(platform)/codex-auth")
    }
}
