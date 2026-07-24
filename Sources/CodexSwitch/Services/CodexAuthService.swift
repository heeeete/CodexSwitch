import AppKit
import Darwin
import Foundation
import Security

@_silgen_name("flock")
private func codexSwitchFlock(_ fileDescriptor: Int32, _ operation: Int32) -> Int32

// 인증 helper, ChatGPT 설치, 계정 스냅샷 오류를 사용자 메시지로 변환한다.
enum CodexAuthError: LocalizedError, Sendable {
    case helperExecutableNotFound
    case commandTimedOut
    case commandFailed(String)
    case credentialRestoreFailed
    case invalidLoginCredential
    case accountAlreadyConnected
    case temporaryCredentialCleanupFailed
    case invalidRegistry
    case unsupportedRegistryVersion(Int)
    case accountNotFound
    case snapshotNotFound
    case registryChanged
    case activeCredentialChanged
    case autoSwitchRunning

    var errorDescription: String? {
        switch self {
        case .helperExecutableNotFound:
            return "앱에 포함된 codex-auth를 찾지 못했습니다. CodexSwitch를 다시 설치해 주세요."
        case .commandTimedOut:
            return "codex-auth 응답이 없어 작업을 중단했습니다. 잠시 후 다시 시도해 주세요."
        case let .commandFailed(message):
            return message.isEmpty ? "계정 명령을 실행하지 못했습니다." : message
        case .credentialRestoreFailed:
            return "인증 파일을 원래 상태로 복구하지 못했습니다. ChatGPT를 열지 말고 CodexSwitch를 종료한 뒤 백업 파일을 확인해 주세요."
        case .invalidLoginCredential:
            return "로그인한 계정의 인증 정보를 확인하지 못했습니다. 계정 추가를 다시 시도해 주세요."
        case .accountAlreadyConnected:
            return "이미 추가된 계정입니다. 상단 계정 목록에서 선택해 주세요."
        case .temporaryCredentialCleanupFailed:
            return "임시 로그인 정보를 지우지 못했습니다. 계정은 이미 추가됐을 수 있습니다. CodexSwitch를 종료한 뒤 계정 목록을 확인해 주세요."
        case .invalidRegistry:
            return "계정 목록 파일을 읽지 못했습니다. codex-auth에서 계정 목록을 확인해 주세요."
        case let .unsupportedRegistryVersion(version):
            return "codex-auth registry v\(version)은 아직 지원하지 않습니다. 안정판 0.2.10 형식(v3)이 필요합니다."
        case .accountNotFound:
            return "선택한 계정이 목록에서 사라졌습니다. 새로 고친 뒤 다시 시도해 주세요."
        case .snapshotNotFound:
            return "선택한 계정의 인증 스냅샷을 찾지 못했습니다. 계정을 다시 연결해 주세요."
        case .registryChanged:
            return "다른 프로세스에서 계정 목록이 변경됐습니다. 새로 고친 뒤 다시 시도해 주세요."
        case .activeCredentialChanged:
            return "현재 ChatGPT 인증이 선택한 계정과 일치하지 않아 제거를 중단했습니다. 계정 목록을 새로 고친 뒤 다시 시도해 주세요."
        case .autoSwitchRunning:
            return "codex-auth 자동 전환이 실행 중이라 수동 전환을 중단했습니다. 자동 전환을 끈 뒤 다시 시도해 주세요."
        }
    }
}

struct AccountRemovalResult: Sendable {
    let credentialCleanupComplete: Bool
}

// upstream daemon과 같은 lock 파일을 사용해 동시에 auth를 바꾸지 않는다.
private final class AutoSwitchFileLock {
    private let fileDescriptor: Int32

    private init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    static func acquire(at url: URL) throws -> AutoSwitchFileLock? {
        let descriptor = url.path.withCString {
            Darwin.open($0, O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        _ = Darwin.fchmod(descriptor, S_IRUSR | S_IWUSR)
        guard codexSwitchFlock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let lockError = errno
            _ = Darwin.close(descriptor)
            if lockError == EWOULDBLOCK || lockError == EAGAIN {
                return nil
            }
            throw POSIXError(POSIXErrorCode(rawValue: lockError) ?? .EIO)
        }
        return AutoSwitchFileLock(fileDescriptor: descriptor)
    }

    deinit {
        _ = codexSwitchFlock(fileDescriptor, LOCK_UN)
        _ = Darwin.close(fileDescriptor)
    }
}

// 브라우저 로그인을 취소할 때 helper와 그 하위 Codex 프로세스까지 종료한다.
private final class ProcessCancellationHandle: @unchecked Sendable {
    private struct ProcessIdentity: Hashable, Sendable {
        let processID: pid_t
        let startSeconds: UInt64
        let startMicroseconds: UInt64
    }

    private let lock = NSLock()
    private let timeout: TimeInterval?
    private var processID: pid_t?
    private var isCancelled = false
    private var didTimeOut = false
    private var isFinished = false
    private var terminationRequested = false
    private var timeoutWorkItem: DispatchWorkItem?

    init(timeout: TimeInterval?) {
        self.timeout = timeout
    }

    func prepareToLaunch() throws {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            throw CancellationError()
        }
    }

    func didLaunch(processID: pid_t) {
        lock.lock()
        self.processID = processID
        let shouldTerminate = terminationRequested
        let timeout = timeout
        let workItem: DispatchWorkItem?
        if !shouldTerminate, timeout != nil {
            let item = DispatchWorkItem { [weak self] in
                self?.requestTermination(timedOut: true)
            }
            timeoutWorkItem = item
            workItem = item
        } else {
            workItem = nil
        }
        lock.unlock()

        if shouldTerminate {
            Self.terminateProcessTree(root: processID)
        } else if let workItem, let timeout {
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + timeout,
                execute: workItem
            )
        }
    }

    func finish() {
        lock.lock()
        isFinished = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        processID = nil
        lock.unlock()
    }

    func cancel() {
        requestTermination(timedOut: false)
    }

    var timedOut: Bool {
        lock.lock()
        defer { lock.unlock() }
        return didTimeOut
    }

    private func requestTermination(timedOut: Bool) {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        if timedOut {
            didTimeOut = true
        } else {
            isCancelled = true
        }
        let isFirstRequest = !terminationRequested
        terminationRequested = true
        timeoutWorkItem?.cancel()
        timeoutWorkItem = nil
        let runningProcessID = processID
        lock.unlock()

        if isFirstRequest, let runningProcessID {
            Self.terminateProcessTree(root: runningProcessID)
        }
    }

    private static func terminateProcessTree(root: pid_t) {
        // 먼저 하위 로그인/Node만 종료해 helper가 정리할 시간을 주고, 이후에만 root를 종료한다.
        let descendantIdentities = descendantProcessIDs(of: root)
            .reversed()
            .compactMap(processIdentity(for:))
        let rootIdentity = processIdentity(for: root)
        let identities = descendantIdentities + [rootIdentity].compactMap { $0 }
        for identity in descendantIdentities {
            _ = Darwin.kill(identity.processID, SIGTERM)
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
            // 첫 자식 종료 뒤 helper가 새 프로세스를 만들었을 수 있어 root 종료 직전에 다시 수집한다.
            let lateDescendantIdentities = descendantProcessIDs(of: root)
                .reversed()
                .compactMap(processIdentity(for:))
            for identity in lateDescendantIdentities
            where processIdentity(for: identity.processID) == identity {
                _ = Darwin.kill(identity.processID, SIGTERM)
            }
            let allIdentities = Array(Set(identities + lateDescendantIdentities))
            if let rootIdentity,
               processIdentity(for: rootIdentity.processID) == rootIdentity {
                _ = Darwin.kill(rootIdentity.processID, SIGTERM)
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 1) {
                forceKillIfStillRunning(allIdentities)
            }
        }
    }

    private static func descendantProcessIDs(of parent: pid_t) -> [pid_t] {
        var result: [pid_t] = []
        var pending = [parent]

        while let current = pending.popLast() {
            var children = [pid_t](repeating: 0, count: 64)
            let byteCount = Int32(children.count * MemoryLayout<pid_t>.stride)
            let count = proc_listchildpids(current, &children, byteCount)
            guard count > 0 else { continue }

            let childCount = min(Int(count), children.count)
            let validChildren = children.prefix(childCount).filter { $0 > 0 }
            result.append(contentsOf: validChildren)
            pending.append(contentsOf: validChildren)
        }
        return result
    }

    private static func processIdentity(for processID: pid_t) -> ProcessIdentity? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else {
            return nil
        }
        return ProcessIdentity(
            processID: processID,
            startSeconds: info.pbi_start_tvsec,
            startMicroseconds: info.pbi_start_tvusec
        )
    }

    private static func forceKillIfStillRunning(_ identities: [ProcessIdentity]) {
        var targets = Set(identities.filter { processIdentity(for: $0.processID) == $0 })
        for target in Array(targets) {
            for descendant in descendantProcessIDs(of: target.processID) {
                if let identity = processIdentity(for: descendant) {
                    targets.insert(identity)
                }
            }
        }
        for target in targets where processIdentity(for: target.processID) == target {
            _ = Darwin.kill(target.processID, SIGKILL)
        }
    }
}

// 파이프를 동시에 비워 교착을 막고 출력 메모리는 상한까지만 보관한다.
private final class ProcessOutputCapture: @unchecked Sendable {
    private static let maximumStoredBytes = 2 * 1_024 * 1_024
    private let lock = NSLock()
    private var data = Data()

    func start(reading handle: FileHandle, group: DispatchGroup) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            defer { group.leave() }
            do {
                while let chunk = try handle.read(upToCount: 64 * 1_024), !chunk.isEmpty {
                    lock.lock()
                    let remaining = Self.maximumStoredBytes - data.count
                    if remaining > 0 {
                        data.append(chunk.prefix(remaining))
                    }
                    lock.unlock()
                }
            } catch {
                // 프로세스 종료 중 파이프가 닫히면 현재까지 받은 출력만 사용한다.
            }
        }
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}

// CLI 사용은 로그인·목록 동기화에 한정하고 실제 계정 전환은 account_key로 처리한다.
actor CodexAuthService {
    private struct ChatGPTRuntime: Sendable {
        let codexPath: String?
        let nodePath: String?
    }

    private struct StagedCredential: Sendable {
        let accountKey: String
        let authURL: URL
        let authData: Data
    }

    private struct CredentialArtifactState: Sendable {
        let existed: Bool
        let data: Data?
    }

    private enum ChatGPTValidation {
        case trusted
        case invalid
    }

    private let registryURL: URL
    private let environment: [String: String]
    private let standardCommandTimeout: TimeInterval
    private let apiCommandTimeout: TimeInterval
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        registryURL: URL = CodexAuthService.defaultRegistryURL,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        standardCommandTimeout: TimeInterval = 30,
        apiCommandTimeout: TimeInterval = 120
    ) {
        self.registryURL = registryURL
        self.environment = environment
        self.standardCommandTimeout = standardCommandTimeout
        self.apiCommandTimeout = apiCommandTimeout
    }

    static var defaultRegistryURL: URL {
        defaultRegistryURL(environment: ProcessInfo.processInfo.environment)
    }

    static func defaultRegistryURL(environment: [String: String]) -> URL {
        let codexHome: URL

        if let configuredHome = environment["CODEX_HOME"], !configuredHome.isEmpty {
            codexHome = URL(fileURLWithPath: configuredHome, isDirectory: true)
        } else {
            codexHome = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".codex", isDirectory: true)
        }

        return codexHome
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent("registry.json", isDirectory: false)
    }

    // registry가 없으면 정상적인 첫 실행으로 간주한다.
    func loadRegistry() throws -> AccountRegistry {
        guard FileManager.default.fileExists(atPath: registryURL.path) else {
            return .empty
        }

        do {
            let data = try Data(contentsOf: registryURL)
            let registry = try JSONDecoder().decode(AccountRegistry.self, from: data)
            guard registry.schemaVersion <= 3 else {
                throw CodexAuthError.unsupportedRegistryVersion(registry.schemaVersion)
            }
            return registry
        } catch let error as CodexAuthError {
            throw error
        } catch {
            throw CodexAuthError.invalidRegistry
        }
    }

    // 기존 registry도 helper로 조정해 마이그레이션과 현재 auth 스냅샷 동기화를 보장한다.
    func loadOrImportLocalRegistry() async throws -> AccountRegistry {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()

        let authURL = registryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("auth.json", isDirectory: false)
        let hasRegistry = FileManager.default.fileExists(atPath: registryURL.path)
        let hasAuth = FileManager.default.fileExists(atPath: authURL.path)
        guard hasRegistry || hasAuth else {
            return .empty
        }

        try preflightRegistrySchemaIfPresent()
        _ = try await run(
            arguments: ["list", "--skip-api"],
            timeout: standardCommandTimeout
        )
        return try loadRegistry()
    }

    // 정확한 조회는 사용자가 명시적으로 동의한 경우에만 비공개 API 모드를 사용한다.
    func refreshAccounts(useDirectAPI: Bool) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()

        if useDirectAPI {
            let runtime = try await resolveChatGPTRuntime(
                requireCodex: false,
                requireNode: true
            )
            _ = try await run(
                arguments: ["list", "--api"],
                nodeExecutablePath: runtime.nodePath,
                timeout: apiCommandTimeout
            )
        } else {
            _ = try await run(
                arguments: ["list", "--skip-api"],
                timeout: standardCommandTimeout
            )
        }
    }

    // 로그인은 격리된 CODEX_HOME에서 끝낸 뒤 새 계정만 실제 목록에 가져온다.
    @discardableResult
    func connectAccount() async throws -> String {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()

        try ensureCodexHomeDirectory()
        let runtime = try await resolveChatGPTRuntime(
            requireCodex: true,
            requireNode: false
        )
        let temporaryHome = try createTemporaryLoginHome()
        var connectedAccountKey: String?
        var operationError: (any Error)?

        do {
            _ = try await run(
                arguments: ["login"],
                codexExecutablePath: runtime.codexPath,
                // 0.2.10은 팀 로그인 직후 선택적 메타데이터 API 실패를 무시한다.
                // 네트워크를 수행하지 않는 실행 파일을 지정해 로그인은 항상 로컬로 끝낸다.
                nodeExecutablePath: "/usr/bin/false",
                codexHomeURL: temporaryHome,
                timeout: nil
            )
            try Task.checkCancellation()

            let stagedCredential = try loadStagedCredential(from: temporaryHome)
            try await importStagedCredential(stagedCredential)
            connectedAccountKey = stagedCredential.accountKey
        } catch {
            operationError = error
        }

        // 성공·실패·취소와 무관하게 토큰이 든 임시 홈은 이번 호출 안에서 제거한다.
        do {
            try removeTemporaryLoginHome(temporaryHome)
        } catch {
            throw CodexAuthError.temporaryCredentialCleanupFailed
        }
        if let operationError {
            throw operationError
        }
        guard let connectedAccountKey else {
            throw CodexAuthError.invalidLoginCredential
        }
        return connectedAccountKey
    }

    private func ensureCodexHomeDirectory() throws {
        try FileManager.default.createDirectory(
            at: codexHomeURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private var codexHomeURL: URL {
        registryURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    // 임시 홈은 앱의 실제 인증 폴더 밖에 만들고 디렉터리 권한을 0700으로 고정한다.
    private func createTemporaryLoginHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexSwitch-Login-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(
                at: url,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: url.path
            )
            guard Self.isDirectoryWithoutSymlink(url) else {
                throw CodexAuthError.invalidLoginCredential
            }
            return url
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func removeTemporaryLoginHome(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    // 격리 로그인 결과의 account_key와 auth.json이 서로 같은 계정인지 검증한다.
    private func loadStagedCredential(from codexHomeURL: URL) throws -> StagedCredential {
        let stagedRegistryURL = codexHomeURL
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent("registry.json", isDirectory: false)
        let authURL = codexHomeURL.appendingPathComponent("auth.json", isDirectory: false)
        guard Self.isRegularFileWithoutSymlink(stagedRegistryURL),
              Self.isRegularFileWithoutSymlink(authURL),
              let registryData = try? Data(contentsOf: stagedRegistryURL),
              let stagedRegistry = try? JSONDecoder().decode(AccountRegistry.self, from: registryData),
              stagedRegistry.schemaVersion <= 3,
              let accountKey = stagedRegistry.activeAccountKey,
              stagedRegistry.accounts.contains(where: { $0.accountKey == accountKey }),
              let authData = try? Data(contentsOf: authURL),
              Self.recordKey(in: authData) == accountKey else {
            throw CodexAuthError.invalidLoginCredential
        }
        return StagedCredential(
            accountKey: accountKey,
            authURL: authURL,
            authData: authData
        )
    }

    // import만 실제 홈에서 실행하므로 live auth와 활성 계정은 건드리지 않는다.
    private func importStagedCredential(_ stagedCredential: StagedCredential) async throws {
        try preflightRegistrySchemaIfPresent()
        let accountsURL = registryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: accountsURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let lockURL = accountsURL.appendingPathComponent("auto-switch.lock", isDirectory: false)
        guard let importLock = try AutoSwitchFileLock.acquire(at: lockURL) else {
            throw CodexAuthError.autoSwitchRunning
        }
        defer { withExtendedLifetime(importLock) {} }

        try Task.checkCancellation()
        let registryBeforeImport = try loadRegistry()
        guard !registryBeforeImport.accounts.contains(where: {
            $0.accountKey == stagedCredential.accountKey
        }) else {
            throw CodexAuthError.accountAlreadyConnected
        }

        let snapshotURL = accountsURL.appendingPathComponent(
            Self.snapshotFileName(accountKey: stagedCredential.accountKey),
            isDirectory: false
        )
        let snapshotBeforeImport = Self.credentialArtifactState(at: snapshotURL)
        guard !snapshotBeforeImport.existed else {
            throw CodexAuthError.accountAlreadyConnected
        }

        // commit 직전 취소만 허용하고, 짧은 import가 시작된 뒤에는 결과를 끝까지 확인한다.
        try Task.checkCancellation()
        do {
            _ = try await runCommitCommand(
                arguments: ["import", stagedCredential.authURL.path],
                nodeExecutablePath: "/usr/bin/false",
                codexHomeURL: codexHomeURL,
                timeout: standardCommandTimeout
            )
        } catch {
            if (try? importIsCommitted(
                accountKey: stagedCredential.accountKey,
                expectedActiveAccountKey: registryBeforeImport.activeAccountKey,
                expectedSnapshotData: stagedCredential.authData,
                snapshotURL: snapshotURL
            )) == true {
                return
            }
            guard let registryAfterFailure = try? loadRegistry() else {
                throw CodexAuthError.invalidRegistry
            }
            guard !registryAfterFailure.accounts.contains(where: {
                $0.accountKey == stagedCredential.accountKey
            }) else {
                throw CodexAuthError.registryChanged
            }
            guard Self.removeUncommittedImportedSnapshot(
                at: snapshotURL,
                importedData: stagedCredential.authData
            ) else {
                throw CodexAuthError.credentialRestoreFailed
            }
            throw error
        }

        guard try importIsCommitted(
            accountKey: stagedCredential.accountKey,
            expectedActiveAccountKey: registryBeforeImport.activeAccountKey,
            expectedSnapshotData: stagedCredential.authData,
            snapshotURL: snapshotURL
        ) else {
            let registryAfterImport = try loadRegistry()
            if !registryAfterImport.accounts.contains(where: {
                $0.accountKey == stagedCredential.accountKey
            }), !Self.removeUncommittedImportedSnapshot(
                at: snapshotURL,
                importedData: stagedCredential.authData
            ) {
                throw CodexAuthError.credentialRestoreFailed
            }
            throw CodexAuthError.registryChanged
        }
    }

    private func importIsCommitted(
        accountKey: String,
        expectedActiveAccountKey: String?,
        expectedSnapshotData: Data,
        snapshotURL: URL
    ) throws -> Bool {
        let registry = try loadRegistry()
        return registry.activeAccountKey == expectedActiveAccountKey
            && registry.accounts.contains(where: { $0.accountKey == accountKey })
            && Self.credentialArtifactState(at: snapshotURL).data == expectedSnapshotData
    }

    // helper보다 먼저 새 schema를 감지해 사용자의 registry를 잘못 마이그레이션하지 않는다.
    private func preflightRegistrySchemaIfPresent() throws {
        guard FileManager.default.fileExists(atPath: registryURL.path) else { return }
        do {
            let data = try Data(contentsOf: registryURL)
            guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let schemaVersion = (root["schema_version"] as? NSNumber)?.intValue else {
                throw CodexAuthError.invalidRegistry
            }
            guard schemaVersion <= 3 else {
                throw CodexAuthError.unsupportedRegistryVersion(schemaVersion)
            }
        } catch let error as CodexAuthError {
            throw error
        } catch {
            throw CodexAuthError.invalidRegistry
        }
    }

    // CLI 행 번호 대신 선택한 account_key의 스냅샷을 직접 적용한다.
    func switchAccount(accountKey: String) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()

        // 현재 auth의 갱신 토큰을 원래 계정 스냅샷에 저장한 뒤 대상 계정을 적용한다.
        try preflightRegistrySchemaIfPresent()
        _ = try await run(
            arguments: ["list", "--skip-api"],
            timeout: standardCommandTimeout
        )
        try Task.checkCancellation()
        let lockURL = registryURL.deletingLastPathComponent()
            .appendingPathComponent("auto-switch.lock", isDirectory: false)
        guard let switchLock = try AutoSwitchFileLock.acquire(at: lockURL) else {
            throw CodexAuthError.autoSwitchRunning
        }
        try withExtendedLifetime(switchLock) {
            try Self.performAtomicSwitch(accountKey: accountKey, registryURL: registryURL)
        }
    }

    // 부분 일치 CLI 대신 고유 account_key로 로컬 계정 하나만 제거한다.
    func removeAccount(
        accountKey: String,
        expectedActive: Bool
    ) async throws -> AccountRemovalResult {
        await acquireMutation()
        defer { releaseMutation() }
        try Task.checkCancellation()

        // live auth를 현재 계정 스냅샷에 먼저 동기화해 최신 토큰을 잃지 않는다.
        try preflightRegistrySchemaIfPresent()
        _ = try await run(
            arguments: ["list", "--skip-api"],
            timeout: standardCommandTimeout
        )
        try Task.checkCancellation()
        let lockURL = registryURL.deletingLastPathComponent()
            .appendingPathComponent("auto-switch.lock", isDirectory: false)
        guard let removalLock = try AutoSwitchFileLock.acquire(at: lockURL) else {
            throw CodexAuthError.autoSwitchRunning
        }
        do {
            return try withExtendedLifetime(removalLock) {
                try Self.performAtomicRemoval(
                    accountKey: accountKey,
                    expectedActive: expectedActive,
                    registryURL: registryURL
                )
            }
        } catch CodexAuthError.registryChanged {
            // foreground 명령과 경합했다면 live auth를 기준으로 registry 일관성을 복구한다.
            _ = try? await run(
                arguments: ["list", "--skip-api"],
                timeout: standardCommandTimeout
            )
            throw CodexAuthError.registryChanged
        }
    }

    private func run(
        arguments: [String],
        codexExecutablePath: String? = nil,
        nodeExecutablePath: String? = nil,
        codexHomeURL: URL? = nil,
        timeout: TimeInterval?
    ) async throws -> String {
        let executablePath = try resolveHelperExecutablePath()
        let processEnvironment = augmentedEnvironment(
            codexExecutablePath: codexExecutablePath,
            nodeExecutablePath: nodeExecutablePath,
            codexHomeURL: codexHomeURL
        )
        let workingDirectory = FileManager.default.homeDirectoryForCurrentUser

        let cancellationHandle = ProcessCancellationHandle(timeout: timeout)
        return try await withTaskCancellationHandler {
            do {
                let output = try await Task.detached(priority: .userInitiated) {
                    try Self.runProcess(
                        executablePath: executablePath,
                        arguments: arguments,
                        environment: processEnvironment,
                        workingDirectory: workingDirectory,
                        cancellationHandle: cancellationHandle
                    )
                }.value
                try Task.checkCancellation()
                return output
            } catch {
                if Task.isCancelled {
                    throw CancellationError()
                }
                throw error
            }
        } onCancel: {
            cancellationHandle.cancel()
        }
    }

    // registry import는 취소 신호로 중간 종료하지 않고 timeout만 적용해 반쪽 commit을 막는다.
    private func runCommitCommand(
        arguments: [String],
        nodeExecutablePath: String?,
        codexHomeURL: URL,
        timeout: TimeInterval
    ) async throws -> String {
        let executablePath = try resolveHelperExecutablePath()
        let processEnvironment = augmentedEnvironment(
            codexExecutablePath: nil,
            nodeExecutablePath: nodeExecutablePath,
            codexHomeURL: codexHomeURL
        )
        let workingDirectory = FileManager.default.homeDirectoryForCurrentUser
        let cancellationHandle = ProcessCancellationHandle(timeout: timeout)

        return try await Task.detached(priority: .userInitiated) {
            try Self.runProcess(
                executablePath: executablePath,
                arguments: arguments,
                environment: processEnvironment,
                workingDirectory: workingDirectory,
                cancellationHandle: cancellationHandle
            )
        }.value
    }

    // stdout/stderr 파이프를 별도 큐에서 계속 비워 큰 출력도 교착 없이 받는다.
    private static func runProcess(
        executablePath: String,
        arguments: [String],
        environment: [String: String],
        workingDirectory: URL,
        cancellationHandle: ProcessCancellationHandle
    ) throws -> String {
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let outputCapture = ProcessOutputCapture()
        let errorCapture = ProcessOutputCapture()
        let captureGroup = DispatchGroup()
        outputCapture.start(reading: outputPipe.fileHandleForReading, group: captureGroup)
        errorCapture.start(reading: errorPipe.fileHandleForReading, group: captureGroup)
        let process = Process()

        // 앱에 고정된 helper만 실행하며 사용자 shell 설정에는 의존하지 않는다.
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        func closeParentWriteHandles() {
            try? outputPipe.fileHandleForWriting.close()
            try? errorPipe.fileHandleForWriting.close()
        }

        do {
            try cancellationHandle.prepareToLaunch()
            try process.run()
            closeParentWriteHandles()
            cancellationHandle.didLaunch(processID: process.processIdentifier)
            process.waitUntilExit()
            cancellationHandle.finish()
        } catch {
            cancellationHandle.finish()
            closeParentWriteHandles()
            captureGroup.wait()
            throw CodexAuthError.commandFailed(error.localizedDescription)
        }

        // 예기치 않은 손자 프로세스가 파이프를 물고 있어도 UI 작업이 무기한 멈추지 않는다.
        if captureGroup.wait(timeout: .now() + 2) == .timedOut {
            try? outputPipe.fileHandleForReading.close()
            try? errorPipe.fileHandleForReading.close()
            _ = captureGroup.wait(timeout: .now() + 1)
        }
        if cancellationHandle.timedOut {
            throw CodexAuthError.commandTimedOut
        }

        let output = outputCapture.text
        let errorOutput = errorCapture.text
        guard process.terminationStatus == 0 else {
            let stderr = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            let stdout = output.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = [stderr, stdout]
                .filter { !$0.isEmpty }
                .joined(separator: "\n")
            throw CodexAuthError.commandFailed(message)
        }

        return output
    }

    private func acquireMutation() async {
        if !mutationInProgress {
            mutationInProgress = true
            return
        }
        await withCheckedContinuation { continuation in
            mutationWaiters.append(continuation)
        }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty {
            mutationInProgress = false
        } else {
            mutationWaiters.removeFirst().resume()
        }
    }

    private func resolveHelperExecutablePath() throws -> String {
        var candidates: [String] = []

        // 배포 앱은 표준 Helpers 위치의 서명된 바이너리를 사용한다.
        candidates.append(
            Bundle.main.bundleURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
                .appendingPathComponent("codex-auth", isDirectory: false)
                .path
        )
        if let legacyURL = Bundle.main.url(forResource: "codex-auth", withExtension: nil) {
            candidates.append(legacyURL.path)
        }
        #if DEBUG
        if let override = environment["CODEX_SWITCH_HELPER_EXECUTABLE"], !override.isEmpty {
            candidates.append(override)
        }

        // SwiftPM 개발 실행에서는 프로젝트의 고정 Vendor 바이너리만 허용한다.
        let platformDirectory: String
        #if arch(arm64)
        platformDirectory = "darwin-arm64"
        #elseif arch(x86_64)
        platformDirectory = "darwin-x86_64"
        #else
        platformDirectory = "unsupported"
        #endif
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("Vendor/codex-auth/bin/\(platformDirectory)/codex-auth")
                .path
        )
        #endif

        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0)
        }) else {
            throw CodexAuthError.helperExecutableNotFound
        }
        return executable
    }

    private func resolveChatGPTRuntime(
        requireCodex: Bool,
        requireNode: Bool
    ) async throws -> ChatGPTRuntime {
        #if DEBUG
        if let codexOverride = environment["CODEX_SWITCH_CODEX_EXECUTABLE"],
           FileManager.default.isExecutableFile(atPath: codexOverride) {
            return ChatGPTRuntime(
                codexPath: codexOverride,
                nodePath: resolveNodeExecutable(in: nil)
            )
        }
        #endif

        // API 갱신은 사용자가 이미 지정한 Node/PATH를 ChatGPT 번들보다 먼저 따른다.
        if !requireCodex,
           let nodePath = resolveNodeExecutable(in: nil) {
            return ChatGPTRuntime(codexPath: nil, nodePath: nodePath)
        }

        #if DEBUG
        let userExecutablesDisabled = environment["CODEX_SWITCH_DISABLE_USER_EXECUTABLES"] == "1"
        #else
        let userExecutablesDisabled = false
        #endif

        // 사용자가 설치한 공식 Codex CLI가 있으면 ChatGPT 앱보다 먼저 사용한다.
        if requireCodex,
           !userExecutablesDisabled,
           let codexCLIPath = resolveUserExecutable(named: "codex") {
            return ChatGPTRuntime(
                codexPath: codexCLIPath,
                nodePath: resolveNodeExecutable(in: nil)
            )
        }

        let workspaceURL = await MainActor.run {
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")
        }
        #if DEBUG
        let chatGPTRuntimeDisabled = environment["CODEX_SWITCH_DISABLE_CHATGPT_RUNTIME"] == "1"
        var appCandidates: [URL] = chatGPTRuntimeDisabled ? [] : [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        ]
        #else
        let chatGPTRuntimeDisabled = false
        var appCandidates: [URL] = [
            URL(fileURLWithPath: "/Applications/ChatGPT.app", isDirectory: true)
        ]
        #endif
        #if DEBUG
        if !chatGPTRuntimeDisabled,
           let configuredApp = environment["CODEX_SWITCH_CHATGPT_APP"],
           !configuredApp.isEmpty {
            appCandidates.insert(URL(fileURLWithPath: configuredApp, isDirectory: true), at: 0)
        }
        #endif
        if !chatGPTRuntimeDisabled {
            if let workspaceURL {
                appCandidates.append(workspaceURL)
            }
            appCandidates.append(
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/ChatGPT.app", isDirectory: true)
            )
        }

        for appURL in Self.uniqueURLs(appCandidates) where FileManager.default.fileExists(atPath: appURL.path) {
            let resourcesURL = appURL
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Resources", isDirectory: true)
            let codexPath = resourcesURL.appendingPathComponent("codex").path
            let nodePath = resolveNodeExecutable(in: resourcesURL)
            guard !requireCodex || FileManager.default.isExecutableFile(atPath: codexPath),
                  !requireNode || nodePath != nil else {
                continue
            }

            switch Self.validateChatGPTBundle(
                at: appURL,
                requireCodex: requireCodex,
                requireNode: requireNode
            ) {
            case .trusted:
                return ChatGPTRuntime(
                    codexPath: requireCodex ? codexPath : nil,
                    nodePath: nodePath
                )
            case .invalid:
                continue
            }
        }

        // 실행 경로가 없어도 helper를 실행해 codex-auth의 원래 오류를 그대로 전달한다.
        return ChatGPTRuntime(
            codexPath: nil,
            nodePath: resolveNodeExecutable(in: nil)
        )
    }

    private func resolveNodeExecutable(in resourcesURL: URL?) -> String? {
        var candidates: [String] = []
        #if DEBUG
        if let override = environment["CODEX_SWITCH_NODE_EXECUTABLE"], !override.isEmpty {
            if let resolved = resolveExecutableReference(override) {
                candidates.append(resolved)
            }
        }
        #endif
        if let override = environment["CODEX_AUTH_NODE_EXECUTABLE"], !override.isEmpty,
           let resolved = resolveExecutableReference(override) {
            candidates.append(resolved)
        }
        if let resourcesURL {
            candidates.append(
                resourcesURL
                    .appendingPathComponent("cua_node/bin/node", isDirectory: false)
                    .path
            )
        }
        if let systemNode = resolveUserExecutable(named: "node") {
            candidates.append(systemNode)
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:))
    }

    private func resolveExecutableReference(_ reference: String) -> String? {
        if reference.contains("/") {
            return FileManager.default.isExecutableFile(atPath: reference) ? reference : nil
        }
        return resolveUserExecutable(named: reference)
    }

    private func resolveUserExecutable(named name: String) -> String? {
        userExecutableDirectories()
            .map { URL(fileURLWithPath: $0, isDirectory: true).appendingPathComponent(name) }
            .first(where: { candidate in
                // ChatGPT 내부 Codex는 별도의 서명 검증 경로에서만 허용한다.
                guard !candidate.standardizedFileURL.path.contains(".app/Contents/") else {
                    return false
                }
                let resolved = candidate.resolvingSymlinksInPath()
                let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
                    && FileManager.default.isExecutableFile(atPath: candidate.path)
            })?
            .path
    }

    private func userExecutableDirectories() -> [String] {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        var directories = environment["PATH"]?
            .split(separator: ":")
            .map(String.init) ?? []
        directories.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "\(homePath)/.local/bin",
            "\(homePath)/.npm-global/bin",
            "\(homePath)/.bun/bin",
            "\(homePath)/.volta/bin",
            "\(homePath)/.asdf/shims",
            "\(homePath)/.local/share/pnpm",
            "\(homePath)/.local/share/fnm/aliases/default/bin"
        ])

        // NVM은 버전별 디렉터리를 쓰므로 설치된 버전의 bin 경로를 함께 확인한다.
        let nvmVersionsURL = URL(
            fileURLWithPath: "\(homePath)/.nvm/versions/node",
            isDirectory: true
        )
        if let nvmVersions = try? FileManager.default.contentsOfDirectory(
            at: nvmVersionsURL,
            includingPropertiesForKeys: nil
        ) {
            directories.append(contentsOf: nvmVersions.sorted {
                $0.lastPathComponent > $1.lastPathComponent
            }.map {
                $0.appendingPathComponent("bin", isDirectory: true).path
            })
        }
        return Self.uniqueStrings(directories)
    }

    private func augmentedEnvironment(
        codexExecutablePath: String?,
        nodeExecutablePath: String?,
        codexHomeURL: URL?
    ) -> [String: String] {
        var result = environment
        var directories: [String] = []

        #if DEBUG
        let userExecutablesDisabled = environment["CODEX_SWITCH_DISABLE_USER_EXECUTABLES"] == "1"
        #else
        let userExecutablesDisabled = false
        #endif

        // 선택한 Codex와 사용자의 Node 설치 경로를 함께 전달해 Finder 실행에서도 CLI wrapper가 동작하게 한다.
        if let codexExecutablePath {
            directories.append(URL(fileURLWithPath: codexExecutablePath).deletingLastPathComponent().path)
        }
        if !userExecutablesDisabled {
            directories.append(contentsOf: userExecutableDirectories().filter {
                !$0.contains(".app/Contents/")
            })
        }
        directories.append(contentsOf: ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
        result["PATH"] = Self.uniqueStrings(directories).joined(separator: ":")
        result["CODEX_AUTH_SKIP_SERVICE_RECONCILE"] = "1"

        if let nodeExecutablePath {
            result["CODEX_AUTH_NODE_EXECUTABLE"] = nodeExecutablePath
        }
        if let codexHomeURL {
            result["CODEX_HOME"] = codexHomeURL.path
        }
        return result
    }

    // 번들, 실제 Codex, Node에 OpenAI 지정 requirement를 각각 적용한다.
    private static func validateChatGPTBundle(
        at appURL: URL,
        requireCodex: Bool,
        requireNode: Bool
    ) -> ChatGPTValidation {
        guard Bundle(url: appURL)?.bundleIdentifier == "com.openai.codex",
              let appExecutableURL = Bundle(url: appURL)?.executableURL,
              isDirectoryWithoutSymlink(appURL),
              isRegularFileWithoutSymlink(appExecutableURL),
              isContained(appExecutableURL, in: appURL) else {
            return .invalid
        }

        let resourcesURL = appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
        let codexURL = resourcesURL.appendingPathComponent("codex", isDirectory: false)
        let nodeURL = resourcesURL.appendingPathComponent("cua_node/bin/node", isDirectory: false)
        var requiredFiles: [(url: URL, identifier: String)] = [
            (appURL, "com.openai.codex")
        ]

        if requireCodex {
            guard isRegularFileWithoutSymlink(codexURL), isContained(codexURL, in: appURL) else {
                return .invalid
            }
            requiredFiles.append((codexURL, "codex"))
        }
        if requireNode {
            guard isRegularFileWithoutSymlink(nodeURL), isContained(nodeURL, in: appURL) else {
                return .invalid
            }
            requiredFiles.append((nodeURL, "node"))
        }

        return requiredFiles.allSatisfy {
            validatesOpenAISignature(at: $0.url, identifier: $0.identifier)
        } ? .trusted : .invalid
    }

    private static func validatesOpenAISignature(at url: URL, identifier: String) -> Bool {
        let requirementText = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"2DC432GLL2\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(
            requirementText as CFString,
            [],
            &requirement
        ) == errSecSuccess,
        let requirement else {
            return false
        }

        var staticCode: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &staticCode) == errSecSuccess,
              let staticCode else {
            return false
        }
        return SecStaticCodeCheckValidity(staticCode, flags, requirement) == errSecSuccess
    }

    private static func isContained(_ childURL: URL, in parentURL: URL) -> Bool {
        let parentPath = parentURL.resolvingSymlinksInPath().standardizedFileURL.path
        let childPath = childURL.resolvingSymlinksInPath().standardizedFileURL.path
        return childPath.hasPrefix(parentPath + "/")
    }

    private static func isDirectoryWithoutSymlink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func isRegularFileWithoutSymlink(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        return values?.isRegularFile == true && values?.isSymbolicLink != true
    }

    private static func performAtomicSwitch(accountKey: String, registryURL: URL) throws {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: registryURL.path) else {
            throw CodexAuthError.accountNotFound
        }

        let originalRegistryData = try Data(contentsOf: registryURL)
        guard var root = try JSONSerialization.jsonObject(with: originalRegistryData) as? [String: Any],
              let schemaVersion = (root["schema_version"] as? NSNumber)?.intValue else {
            throw CodexAuthError.invalidRegistry
        }
        guard schemaVersion <= 3 else {
            throw CodexAuthError.unsupportedRegistryVersion(schemaVersion)
        }
        guard var accounts = root["accounts"] as? [[String: Any]],
              let accountIndex = accounts.firstIndex(where: {
                  $0["account_key"] as? String == accountKey
              }) else {
            throw CodexAuthError.accountNotFound
        }

        let accountsURL = registryURL.deletingLastPathComponent()
        let codexHomeURL = accountsURL.deletingLastPathComponent()
        let snapshotURL = accountsURL
            .appendingPathComponent(snapshotFileName(accountKey: accountKey), isDirectory: false)
        let snapshotValues = try? snapshotURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard snapshotValues?.isRegularFile == true,
              snapshotValues?.isSymbolicLink != true,
              let snapshotData = try? Data(contentsOf: snapshotURL),
              (try? JSONSerialization.jsonObject(with: snapshotData)) is [String: Any] else {
            throw CodexAuthError.snapshotNotFound
        }

        // 원본 registry가 바뀌었으면 오래된 선택을 적용하지 않는다.
        guard (try? Data(contentsOf: registryURL)) == originalRegistryData else {
            throw CodexAuthError.registryChanged
        }

        let now = Date().timeIntervalSince1970
        root["active_account_key"] = accountKey
        root["active_account_activated_at_ms"] = Int64(now * 1_000)
        accounts[accountIndex]["last_used_at"] = Int64(now)
        root["accounts"] = accounts
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CodexAuthError.invalidRegistry
        }
        let updatedRegistryData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )

        let authURL = codexHomeURL.appendingPathComponent("auth.json", isDirectory: false)
        let originalAuthData: Data?
        do {
            originalAuthData = try Data(contentsOf: authURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            originalAuthData = nil
        }
        if originalAuthData != snapshotData, let originalAuthData {
            try createBackup(data: originalAuthData, baseName: "auth.json", directory: accountsURL)
        }
        try createBackup(data: originalRegistryData, baseName: "registry.json", directory: accountsURL)

        // 백업 중 외부 helper가 registry를 바꿨으면 사용자 변경을 덮어쓰지 않는다.
        guard (try? Data(contentsOf: registryURL)) == originalRegistryData else {
            throw CodexAuthError.registryChanged
        }

        // auth와 registry를 각각 원자 교체하고 registry 실패 시 auth를 원상 복구한다.
        try writeSensitiveData(snapshotData, to: authURL)
        do {
            guard (try? Data(contentsOf: registryURL)) == originalRegistryData else {
                throw CodexAuthError.registryChanged
            }
            try writeSensitiveData(updatedRegistryData, to: registryURL)
        } catch {
            if let originalAuthData {
                try? writeSensitiveData(originalAuthData, to: authURL)
            } else {
                try? fileManager.removeItem(at: authURL)
            }
            throw error
        }
    }

    private static func performAtomicRemoval(
        accountKey: String,
        expectedActive: Bool,
        registryURL: URL
    ) throws -> AccountRemovalResult {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: registryURL.path) else {
            throw CodexAuthError.accountNotFound
        }

        // 원본 JSON의 알 수 없는 필드는 보존하고 삭제 대상만 account_key로 찾는다.
        let originalRegistryData = try Data(contentsOf: registryURL)
        guard var root = try JSONSerialization.jsonObject(with: originalRegistryData) as? [String: Any],
              let schemaVersion = (root["schema_version"] as? NSNumber)?.intValue else {
            throw CodexAuthError.invalidRegistry
        }
        guard schemaVersion <= 3 else {
            throw CodexAuthError.unsupportedRegistryVersion(schemaVersion)
        }
        guard var accounts = root["accounts"] as? [[String: Any]],
              let accountIndex = accounts.firstIndex(where: {
                  $0["account_key"] as? String == accountKey
              }) else {
            throw CodexAuthError.accountNotFound
        }
        let isActive = root["active_account_key"] as? String == accountKey
        guard isActive == expectedActive else {
            throw CodexAuthError.registryChanged
        }

        let accountsURL = registryURL.deletingLastPathComponent()
        let codexHomeURL = accountsURL.deletingLastPathComponent()
        let authURL = codexHomeURL.appendingPathComponent("auth.json", isDirectory: false)
        let removedSnapshotURL = accountsURL.appendingPathComponent(
            snapshotFileName(accountKey: accountKey),
            isDirectory: false
        )
        let removedSnapshotState = credentialArtifactState(at: removedSnapshotURL)
        let originalAuthData = isActive ? try readOptionalFileData(at: authURL) : nil

        // 활성 계정은 helper 동기화 결과와 live auth가 정확히 같을 때만 교체한다.
        if isActive, let originalAuthData {
            let authValues = try? authURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard authValues?.isRegularFile == true,
                  authValues?.isSymbolicLink != true,
                  removedSnapshotState.data == originalAuthData else {
                throw CodexAuthError.activeCredentialChanged
            }
        }

        let decodedRegistry: AccountRegistry
        do {
            decodedRegistry = try JSONDecoder().decode(AccountRegistry.self, from: originalRegistryData)
        } catch {
            throw CodexAuthError.invalidRegistry
        }

        // 활성 계정을 지우면 upstream과 같은 사용량 점수로 남은 최적 계정을 고른다.
        let replacement = isActive
            ? bestRemainingAccount(in: decodedRegistry, excluding: accountKey)
            : nil
        var replacementAuthData: Data?
        if let replacement {
            let replacementSnapshotURL = accountsURL.appendingPathComponent(
                snapshotFileName(accountKey: replacement.accountKey),
                isDirectory: false
            )
            let snapshotValues = try? replacementSnapshotURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard snapshotValues?.isRegularFile == true,
                  snapshotValues?.isSymbolicLink != true,
                  let snapshotData = try? Data(contentsOf: replacementSnapshotURL),
                  (try? JSONSerialization.jsonObject(with: snapshotData)) is [String: Any] else {
                throw CodexAuthError.snapshotNotFound
            }
            replacementAuthData = snapshotData

            let now = Date().timeIntervalSince1970
            root["active_account_key"] = replacement.accountKey
            root["active_account_activated_at_ms"] = Int64(now * 1_000)
            if let replacementIndex = accounts.firstIndex(where: {
                $0["account_key"] as? String == replacement.accountKey
            }) {
                accounts[replacementIndex]["last_used_at"] = Int64(now)
            }
        } else if isActive {
            root["active_account_key"] = NSNull()
            root["active_account_activated_at_ms"] = NSNull()
        }

        accounts.remove(at: accountIndex)
        root["accounts"] = accounts
        guard JSONSerialization.isValidJSONObject(root) else {
            throw CodexAuthError.invalidRegistry
        }
        let updatedRegistryData = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys]
        )

        // registry 변경을 백업하고 외부 변경이 없을 때만 인증 파일을 교체한다.
        try createBackup(data: originalRegistryData, baseName: "registry.json", directory: accountsURL)
        guard (try? Data(contentsOf: registryURL)) == originalRegistryData else {
            throw CodexAuthError.registryChanged
        }
        if isActive {
            guard try readOptionalFileData(at: authURL) == originalAuthData else {
                throw CodexAuthError.activeCredentialChanged
            }
            if let replacementAuthData {
                try writeSensitiveData(replacementAuthData, to: authURL)
            } else if fileManager.fileExists(atPath: authURL.path) {
                try fileManager.removeItem(at: authURL)
            }
        }

        // registry 쓰기가 실패하면 이 작업이 적용한 auth만 원래 상태로 되돌린다.
        do {
            guard (try? Data(contentsOf: registryURL)) == originalRegistryData else {
                throw CodexAuthError.registryChanged
            }
            try writeSensitiveData(updatedRegistryData, to: registryURL)
            guard (try? Data(contentsOf: registryURL)) == updatedRegistryData else {
                throw CodexAuthError.registryChanged
            }
            if isActive {
                guard try readOptionalFileData(at: authURL) == replacementAuthData else {
                    throw CodexAuthError.registryChanged
                }
            }
        } catch {
            let registryStillOriginal = (try? Data(contentsOf: registryURL)) == originalRegistryData
            if isActive, registryStillOriginal {
                do {
                    try restoreAuthIfTransactionStillOwnsFile(
                        originalData: originalAuthData,
                        appliedData: replacementAuthData,
                        at: authURL
                    )
                } catch {
                    throw CodexAuthError.credentialRestoreFailed
                }
            }
            throw error
        }

        // commit 뒤 대상 스냅샷과 그 계정에 속한 auth 백업만 정리한다.
        let snapshotCleanupComplete = removeFileIfUnchanged(
            at: removedSnapshotURL,
            originalState: removedSnapshotState
        )
        let backupCleanupComplete = removeCredentialBackups(for: accountKey, in: accountsURL)

        // 같은 계정이 동시에 다시 등록됐다면 새 스냅샷을 지운 상태로 남기지 않는다.
        if registryContainsAccount(accountKey, at: registryURL) {
            let currentState = credentialArtifactState(at: removedSnapshotURL)
            if !currentState.existed, let originalSnapshotData = removedSnapshotState.data {
                do {
                    try writeSensitiveData(originalSnapshotData, to: removedSnapshotURL)
                } catch {
                    throw CodexAuthError.credentialRestoreFailed
                }
            }
            throw CodexAuthError.registryChanged
        }
        return AccountRemovalResult(
            credentialCleanupComplete: snapshotCleanupComplete && backupCleanupComplete
        )
    }

    private static func bestRemainingAccount(
        in registry: AccountRegistry,
        excluding accountKey: String
    ) -> CodexAccount? {
        let now = Int64(Date().timeIntervalSince1970)
        var bestAccount: CodexAccount?
        var bestScore: Int64 = -2
        var bestSeen: Int64 = -1

        for account in registry.accounts where account.accountKey != accountKey {
            let score = usageScore(account.lastUsage, now: now) ?? -1
            let seen = account.lastUsageAt ?? -1
            if score > bestScore || (score == bestScore && seen > bestSeen) {
                bestAccount = account
                bestScore = score
                bestSeen = seen
            }
        }
        return bestAccount
    }

    private static func usageScore(_ usage: UsageSnapshot?, now: Int64) -> Int64? {
        guard let usage else { return nil }
        let fiveHour = resolvedUsageWindow(usage, minutes: 300, fallbackToPrimary: true)
        let weekly = resolvedUsageWindow(usage, minutes: 10_080, fallbackToPrimary: false)
        let fiveHourRemaining = remainingPercent(fiveHour, now: now)
        let weeklyRemaining = remainingPercent(weekly, now: now)

        if let fiveHourRemaining, let weeklyRemaining {
            return min(fiveHourRemaining, weeklyRemaining)
        }
        return fiveHourRemaining ?? weeklyRemaining
    }

    private static func resolvedUsageWindow(
        _ usage: UsageSnapshot,
        minutes: Int,
        fallbackToPrimary: Bool
    ) -> UsageWindow? {
        if usage.primary?.windowMinutes == minutes { return usage.primary }
        if usage.secondary?.windowMinutes == minutes { return usage.secondary }
        return fallbackToPrimary ? usage.primary : usage.secondary
    }

    private static func remainingPercent(_ window: UsageWindow?, now: Int64) -> Int64? {
        guard let window else { return nil }
        if let resetsAt = window.resetsAt, resetsAt <= now { return 100 }
        return Int64(max(0, min(100, 100 - window.usedPercent)))
    }

    private static func readOptionalFileData(at url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private static func restoreAuthIfTransactionStillOwnsFile(
        originalData: Data?,
        appliedData: Data?,
        at url: URL
    ) throws {
        // 다른 foreground 명령이 새 auth를 썼다면 그 최신 값을 덮어쓰지 않는다.
        guard try readOptionalFileData(at: url) == appliedData else { return }
        if let originalData {
            try writeSensitiveData(originalData, to: url)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    private static func credentialArtifactState(at url: URL) -> CredentialArtifactState {
        let fileManager = FileManager.default
        let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        let existed = fileManager.fileExists(atPath: url.path)
            || values?.isSymbolicLink == true
        let data: Data?
        if values?.isRegularFile == true, values?.isSymbolicLink != true {
            data = try? Data(contentsOf: url)
        } else {
            data = nil
        }
        return CredentialArtifactState(existed: existed, data: data)
    }

    private static func removeFileIfUnchanged(
        at url: URL,
        originalState: CredentialArtifactState
    ) -> Bool {
        let currentState = credentialArtifactState(at: url)
        guard currentState.existed else { return true }
        guard originalState.existed,
              let originalData = originalState.data,
              currentState.data == originalData else {
            return false
        }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    // import가 registry에 반영되지 않았을 때 이번 호출이 새로 쓴 스냅샷만 제거한다.
    private static func removeUncommittedImportedSnapshot(
        at url: URL,
        importedData: Data
    ) -> Bool {
        let currentState = credentialArtifactState(at: url)
        guard currentState.existed else { return true }
        guard currentState.data == importedData else { return false }
        do {
            try FileManager.default.removeItem(at: url)
            return true
        } catch {
            return false
        }
    }

    private static func registryContainsAccount(_ accountKey: String, at registryURL: URL) -> Bool {
        guard let data = try? Data(contentsOf: registryURL),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let accounts = root["accounts"] as? [[String: Any]] else {
            return false
        }
        return accounts.contains { $0["account_key"] as? String == accountKey }
    }

    private static func removeCredentialBackups(
        for accountKey: String,
        in directory: URL
    ) -> Bool {
        let fileManager = FileManager.default
        guard let backupURLs = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return false }
        var cleanupComplete = true

        for backupURL in backupURLs where backupURL.lastPathComponent.hasPrefix("auth.json.bak.") {
            let values = try? backupURL.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
            guard values?.isRegularFile == true, values?.isSymbolicLink != true else {
                cleanupComplete = false
                continue
            }
            guard let data = try? Data(contentsOf: backupURL),
                  let backupAccountKey = recordKey(in: data) else {
                cleanupComplete = false
                continue
            }
            guard backupAccountKey == accountKey else {
                continue
            }
            do {
                try fileManager.removeItem(at: backupURL)
            } catch {
                cleanupComplete = false
            }
        }
        return cleanupComplete
    }

    private static func recordKey(in authData: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: authData) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let tokenAccountID = tokens["account_id"] as? String,
              let idToken = tokens["id_token"] as? String else {
            return nil
        }
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let payload = decodeBase64URL(String(segments[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let authClaims = claims["https://api.openai.com/auth"] as? [String: Any],
              let claimAccountID = authClaims["chatgpt_account_id"] as? String,
              claimAccountID == tokenAccountID,
              let userID = (authClaims["chatgpt_user_id"] as? String)
                ?? (authClaims["user_id"] as? String) else {
            return nil
        }
        return "\(userID)::\(tokenAccountID)"
    }

    private static func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder != 0 {
            base64.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: base64)
    }

    private static func snapshotFileName(accountKey: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        let needsEncoding = accountKey.isEmpty
            || accountKey == "."
            || accountKey == ".."
            || accountKey.unicodeScalars.contains(where: { !allowed.contains($0) })
        guard needsEncoding else { return "\(accountKey).auth.json" }

        let encoded = Data(accountKey.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "\(encoded).auth.json"
    }

    private static func writeSensitiveData(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        // 처음부터 0600인 같은 디렉터리의 임시 파일을 fsync한 뒤 원자 교체한다.
        let temporaryURL = url.deletingLastPathComponent()
            .appendingPathComponent(".CodexSwitch-\(UUID().uuidString).tmp")
        guard fileManager.createFile(
            atPath: temporaryURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw CodexAuthError.commandFailed("보안 임시 파일을 만들지 못했습니다.")
        }

        do {
            let handle = try FileHandle(forWritingTo: temporaryURL)
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()

            guard Darwin.rename(temporaryURL.path, url.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? fileManager.removeItem(at: temporaryURL)
            throw error
        }
    }

    private static func createBackup(data: Data, baseName: String, directory: URL) throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stem = "\(baseName).bak.\(formatter.string(from: Date()))"

        var attempt = 0
        var backupURL: URL
        repeat {
            let suffix = attempt == 0 ? "" : ".\(attempt)"
            backupURL = directory.appendingPathComponent("\(stem)\(suffix)")
            attempt += 1
        } while FileManager.default.fileExists(atPath: backupURL.path)

        try writeSensitiveData(data, to: backupURL)
        try pruneBackups(baseName: baseName, directory: directory, keeping: 5)
    }

    private static func pruneBackups(baseName: String, directory: URL, keeping count: Int) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .isRegularFileKey]
        let backups = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys))
            .filter { url in
                guard url.lastPathComponent.hasPrefix("\(baseName).bak.") else { return false }
                return (try? url.resourceValues(forKeys: keys).isRegularFile) == true
            }
            .sorted { lhs, rhs in
                let leftDate = (try? lhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                let rightDate = (try? rhs.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
                return leftDate > rightDate
            }

        for staleURL in backups.dropFirst(count) {
            try? FileManager.default.removeItem(at: staleURL)
        }
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func uniqueStrings(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
