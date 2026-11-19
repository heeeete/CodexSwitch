import AppKit
import Darwin
import Foundation

// Claude 데스크톱의 암호화된 로그인과 표시용 메타데이터만 이 Mac에 보관한다.
actor ClaudeAuthService: AccountService {
    struct Runtime: Sendable {
        var isRunning: @MainActor @Sendable () -> Bool
        var stop: @MainActor @Sendable () async throws -> Void
        var open: @MainActor @Sendable () async throws -> Bool

        static let live = Runtime(
            isRunning: {
                NSWorkspace.shared.runningApplications.contains {
                    $0.bundleIdentifier?.hasPrefix("com.anthropic.claudefordesktop") == true
                }
            },
            stop: { _ = try await ChatGPTAppController(provider: .claude).stopIfRunning() },
            open: { try await ChatGPTAppController(provider: .claude).open() }
        )
    }

    private struct Account: Codable {
        var id: String
        var email: String
        var name: String?
        var plan: String?
        var usage: UsageSnapshot?
        var checkedAt: Int64?

        // 유료 요금제로 확인된 계정만 사용량이 비었을 때 구독 없음으로 단정하지 않는다.
        var hasPaidPlan: Bool {
            ["pro", "max", "team", "enterprise"].contains(plan?.lowercased() ?? "")
        }

        // 초기화 시각 없이 기록된 값은 그 기간이 지나면 현재 사용량으로 쓰지 않는다.
        func currentUsage(now: Date) -> UsageSnapshot? {
            func current(_ window: UsageWindow?) -> UsageWindow? {
                guard let window, window.resetsAt == nil, let checkedAt, let minutes = window.windowMinutes,
                      now.timeIntervalSince1970 - Double(checkedAt) >= Double(minutes * 60) else { return window }
                return nil
            }
            let primary = current(usage?.primary)
            let secondary = current(usage?.secondary)
            guard primary != nil || secondary != nil else { return nil }
            let scoped = usage?.scoped?.compactMap(current)
            return UsageSnapshot(primary: primary, secondary: secondary, planType: usage?.planType,
                                 scoped: scoped?.isEmpty == false ? scoped : nil)
        }

        // 표시할 값이 없을 때만 원인을 붙이고, 오래돼 숨긴 기록은 그 시각을 함께 알린다.
        func displayAccount(issues: [any Error], now: Date = Date()) -> CodexAccount {
            let shown = currentUsage(now: now)
            var notes = shown == nil ? issues : []
            if shown == nil, let checkedAt, usage?.primary != nil || usage?.secondary != nil {
                notes.insert(ClaudeUsageError.staleLocalRecord(Date(timeIntervalSince1970: Double(checkedAt))), at: 0)
            }
            // 구독하지 않은 계정은 조회 실패 같은 다른 안내를 덧붙이지 않고 그 사실만 분명히 보여 준다.
            let unsubscribed = notes.first as? ClaudeUsageError == .notSubscribed
            if unsubscribed { notes = [ClaudeUsageError.notSubscribed] }
            return CodexAccount(accountKey: id, email: email, alias: nil, accountName: name,
                                plan: unsubscribed ? "Free" : plan, authMode: "claude", lastUsedAt: nil,
                                lastUsageAt: checkedAt, lastUsage: shown, usageIssues: notes)
        }
    }

    private struct Registry: Codable {
        var version = 1
        var accounts: [Account] = []
    }

    // 쿠키와 인증 캐시는 암호화 상태를 유지하고, 다른 앱 설정은 교체하지 않는다.
    private struct Snapshot: Codable {
        var auth: [String: Data]
        var cookies: [String: Data]

        var accountID: String? {
            guard let data = auth["lastKnownAccountUuid"],
                  let id = try? JSONDecoder().decode(String.self, from: data),
                  UUID(uuidString: id) != nil else { return nil }
            return id
        }

        var encryptedCache: String? {
            auth["oauth:tokenCacheV2"].flatMap { try? JSONDecoder().decode(String.self, from: $0) }
        }
    }

    // 강제 종료나 전원 중단 뒤에도 원래 인증과 계정 목록을 복구할 수 있게 남긴다.
    private struct Recovery: Codable {
        var snapshot: Snapshot
        var registry: Data?
    }

    private static let authKeys = ["oauth:tokenCache", "oauth:tokenCacheV2", "lastKnownAccountUuid"]
    private static let cookieNames = ["Cookies", "Cookies-journal", "Cookies-wal", "Cookies-shm"]
    private let dataDirectory: URL
    private let logDirectory: URL
    private let storageDirectory: URL
    private let runtime: Runtime
    private let client: ClaudeUsageClient
    private let webClient: ClaudeWebClient
    private let loginTimeout: Duration
    private let pollInterval: Duration
    private var blockedUntil: [String: Date] = [:]
    private var usageIssues: [String: [any Error]] = [:]
    private var desktopOrganizations: [String: String] = [:]
    private var mutationInProgress = false
    private var mutationWaiters: [CheckedContinuation<Void, Never>] = []

    init(
        dataDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Claude", isDirectory: true),
        logDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Claude", isDirectory: true),
        storageDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexSwitch/Claude", isDirectory: true),
        runtime: Runtime = .live,
        client: ClaudeUsageClient = ClaudeUsageClient(),
        webClient: ClaudeWebClient = ClaudeWebClient(),
        loginTimeout: Duration = .seconds(900),
        pollInterval: Duration = .seconds(1)
    ) {
        self.dataDirectory = dataDirectory
        self.logDirectory = logDirectory
        self.storageDirectory = storageDirectory
        self.runtime = runtime
        self.client = client
        self.webClient = webClient
        self.loginTimeout = loginTimeout
        self.pollInterval = pollInterval
    }

    private var configURL: URL { dataDirectory.appendingPathComponent("config.json") }
    private var registryURL: URL { storageDirectory.appendingPathComponent("registry.json") }
    private var recoveryURL: URL { storageDirectory.appendingPathComponent("recovery.json") }

    func loadRegistry() throws -> AccountRegistry {
        let registry = try readRegistry()
        let active = try readAuth().accountID
        return AccountRegistry(schemaVersion: 3, activeAccountKey: active, api: nil,
                               accounts: registry.accounts.map { $0.displayAccount(issues: usageIssues[$0.id] ?? []) })
    }

    // 앱이 없거나 로그인 이력이 없는 첫 실행에는 폴더 생성이나 키체인 요청을 하지 않는다.
    // 데스크톱 기록만 반영해 목록을 바로 돌려주고, 서버 응답이 필요한 실시간 조회는 이후 새로고침에 맡긴다.
    func loadOrImportLocalRegistry() async throws -> AccountRegistry {
        await acquireMutation()
        defer { releaseMutation() }
        try await recoverIfNeeded()
        var registry = try readRegistry()
        let auth = try readAuth()
        if let id = auth.accountID { registerCurrent(id, in: &registry) }
        let readings = desktopReadings(registry.accounts.map(\.id))
        for id in registry.accounts.map(\.id) {
            recordIssues(localIssues(applying: readings[id], id: id, registry: &registry), id: id)
        }
        if !registry.accounts.isEmpty { try writeRegistry(registry) }
        return try loadRegistry()
    }

    func refreshAccounts() async throws {
        try await refreshAccounts(interactive: false)
    }

    // 수동 갱신만 키체인 승인을 요청하고, 계정 하나의 실패가 다른 계정 갱신을 막지 않는다.
    func refreshAccounts(interactive: Bool) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        try await recoverIfNeeded()
        var registry = try readRegistry()
        let auth = try readAuth()
        if let id = auth.accountID { registerCurrent(id, in: &registry) }
        let ids = registry.accounts.map(\.id)
        // 데스크톱 기록을 먼저 반영하며 이 단계는 키체인과 네트워크를 쓰지 않는다.
        let readings = desktopReadings(ids)
        var issues: [String: [any Error]] = [:]
        for id in ids { issues[id] = localIssues(applying: readings[id], id: id, registry: &registry) }
        // 계정별 실시간 조회는 서로 독립이므로 동시에 보내 계정 수만큼 기다리지 않게 한다.
        // 릴리스 최적화 빌드에서 TaskGroup이 자식 결과를 하나도 돌려주지 않아 조회 결과가 버려졌으므로,
        // 계정별 Task를 직접 만들고 새로 고침이 취소되면 그 취소를 각 조회에 전달한다.
        let tasks = ids.map { id in
            (id, Task { () -> Result<LiveReading, any Error> in
                do { return .success(try await self.liveReading(id: id, auth: auth, interactive: interactive)) }
                catch { return .failure(error) }
            })
        }
        let lookups = await withTaskCancellationHandler {
            var results: [String: Result<LiveReading, any Error>] = [:]
            for (id, task) in tasks { results[id] = await task.value }
            return results
        } onCancel: {
            for (_, task) in tasks { task.cancel() }
        }
        try Task.checkCancellation()
        // 자동 갱신의 키체인 미승인은 현재 계정에 표시할 사용량이 있으면 어느 계정의 것이든 매번 오류로 알리지 않는다.
        // 구독하지 않은 현재 계정도 가져올 값이 없으므로 같은 오류를 반복해서 알리지 않는다.
        let activeHasUsage = registry.accounts.first { $0.id == auth.accountID }?.currentUsage(now: Date()) != nil
            || auth.accountID.flatMap { issues[$0]?.first as? ClaudeUsageError } == .notSubscribed
        // 결과는 저장된 계정 순서대로 반영해 오류 안내와 기록이 조회 완료 순서에 좌우되지 않게 한다.
        var activeError: (any Error)?
        var firstError: (any Error)?
        var successes = 0
        for id in ids {
            switch lookups[id] {
            case let .success(reading)?:
                issues[id] = applyLiveReading(reading, id: id, registry: &registry).map { [$0] } ?? []
                successes += 1
            case let .failure(error)?:
                if case let ClaudeUsageError.rateLimited(until) = error { blockedUntil[id] = until }
                issues[id, default: []].append(error)
                // 조회 제한은 직전 값이 그대로 남으므로, 현재 계정에 보여 줄 값이 있으면 수동 갱신에서도 알리지 않는다.
                let quietRateLimit: Bool
                if case ClaudeUsageError.rateLimited = error { quietRateLimit = activeHasUsage } else { quietRateLimit = false }
                if !quietRateLimit, interactive || !activeHasUsage || error as? ClaudeUsageError != .keychainUnavailable {
                    if firstError == nil { firstError = error }
                    if id == auth.accountID { activeError = error }
                }
            case nil:
                break
            }
            recordIssues(issues[id] ?? [], id: id)
        }
        if !registry.accounts.isEmpty || FileManager.default.fileExists(atPath: registryURL.path) {
            try writeRegistry(registry)
        }
        if let activeError { throw activeError }
        if successes == 0, let firstError { throw firstError }
    }

    private typealias LiveReading = (profile: ClaudeProfile, usage: UsageSnapshot)

    // 조회 제한이 풀리지 않은 계정은 요청하지 않고, 활성 계정은 실행 중인 앱의 인증을 그대로 사용한다.
    private func liveReading(id: String, auth: Snapshot, interactive: Bool) async throws -> LiveReading {
        if let until = blockedUntil[id], until > Date() { throw ClaudeUsageError.rateLimited(until) }
        let snapshot = id == auth.accountID ? auth : try readSnapshot(id)
        return try await desktopReading(snapshot, id: id, liveCookies: id == auth.accountID, interactive: interactive)
    }

    // 서버가 인증한 계정 UUID와 스냅샷의 UUID가 일치할 때만 사용량을 해당 계정에 기록한다.
    // 조회는 성공했지만 서버가 두 기간 모두 제공하지 않으면 이전 값을 유지하고 그 사실을 돌려준다.
    private func applyLiveReading(_ reading: LiveReading, id: String, registry: inout Registry) -> ClaudeUsageError? {
        guard let index = registry.accounts.firstIndex(where: { $0.id == id }) else { return nil }
        registry.accounts[index].email = reading.profile.email
        registry.accounts[index].name = nil
        registry.accounts[index].plan = reading.profile.plan
        blockedUntil[id] = nil
        guard reading.usage.primary != nil || reading.usage.secondary != nil else {
            // 서버가 유료 요금제도 사용량도 알려 주지 않는 계정은 구독하지 않은 계정으로 기록한다.
            guard registry.accounts[index].hasPaidPlan else {
                registry.accounts[index].plan = "Free"
                return .notSubscribed
            }
            return .usageNotProvided
        }
        registry.accounts[index].usage = reading.usage
        registry.accounts[index].checkedAt = Int64(Date().timeIntervalSince1970)
        return nil
    }

    // 표본·로그·세션 폴더만 읽으며, 읽지 못한 보조 자료는 없는 것으로 보고 귀속을 추측하지 않는다.
    private func desktopReadings(_ ids: [String]) -> [String: ClaudeDesktopUsage.Reading] {
        let history = (try? readIfPresent(dataDirectory.appendingPathComponent("plan-usage-history.json"))) ?? nil
        var log = Data()
        let logURL = logDirectory.appendingPathComponent("main.log")
        if (try? validatePath(logURL)) != nil, let handle = try? FileHandle(forReadingFrom: logURL) {
            // 최근 계정 전환만 필요하므로 큰 로그는 끝부분만 읽는다.
            let size = (try? handle.seekToEnd()) ?? 0
            try? handle.seek(toOffset: size > 4_194_304 ? size - 4_194_304 : 0)
            log = (try? handle.readToEnd()) ?? Data()
            try? handle.close()
        }
        var folders: [String: Set<String>] = [:]
        let root = dataDirectory.appendingPathComponent("claude-code-sessions", isDirectory: true)
        for account in (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [] where UUID(uuidString: account) != nil {
            let organizations = (try? FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent(account).path)) ?? []
            for organization in organizations where UUID(uuidString: organization) != nil {
                folders[organization.lowercased(), default: []].insert(account.lowercased())
            }
        }
        let sessions = ClaudeDesktopUsage.sessions(log: log)
        // 실시간 조회가 데스크톱과 같은 조직을 보도록 계정마다 마지막으로 열린 조직을 기억한다.
        desktopOrganizations = Dictionary(sessions.map { ($0.account, $0.organization) }, uniquingKeysWith: { _, last in last })
        return ClaudeDesktopUsage.readings(history: history, sessions: sessions, folders: folders, accounts: ids)
    }

    // 파일 오류의 설명에는 홈 폴더 경로가 들어 있어, 앱이 정의한 오류가 아니면 도메인과 코드만 남긴다.
    static func logDescription(_ issue: any Error) -> String {
        if issue is ClaudeUsageError || issue is ClaudeAuthError { return String(describing: issue) }
        let error = issue as NSError
        return "\(error.domain)(\(error.code))"
    }

    // 더 새로운 데스크톱 기록만 반영해 온라인으로 확인한 최신 값을 오래된 표본으로 덮지 않는다.
    private func localIssues(applying reading: ClaudeDesktopUsage.Reading?, id: String, registry: inout Registry) -> [any Error] {
        switch reading ?? .noRecord {
        case let .sample(fiveHour, weekly, recordedAt):
            guard let index = registry.accounts.firstIndex(where: { $0.id == id }),
                  recordedAt > (registry.accounts[index].checkedAt ?? 0) else { return [] }
            let previous = registry.accounts[index].usage
            // 같은 기간이 끝나기 전의 표본이면 서버가 알려 준 초기화 시각이 그대로 유효하다.
            func window(_ used: Double?, minutes: Int, previous: UsageWindow?) -> UsageWindow? {
                guard let used else { return nil }
                return UsageWindow(usedPercent: used, windowMinutes: minutes,
                                   resetsAt: previous?.resetsAt.flatMap { $0 > recordedAt ? $0 : nil })
            }
            registry.accounts[index].usage = UsageSnapshot(
                primary: window(fiveHour, minutes: 300, previous: previous?.primary),
                secondary: window(weekly, minutes: 10_080, previous: previous?.secondary),
                planType: previous?.planType,
                // 데스크톱 기록에는 모델별 한도가 없어, 같은 주간 기간 안에서는 마지막으로 조회한 값을 유지한다.
                scoped: previous?.scoped?.filter { ($0.resetsAt ?? 0) > recordedAt })
            registry.accounts[index].checkedAt = recordedAt
            return []
        case .noRecord: return [ClaudeUsageError.noLocalRecord]
        case .notProvided:
            // 데스크톱이 한도 없이 기록한 계정은 유료 요금제로 확인된 적이 없으면 구독하지 않은 계정이다.
            let paid = registry.accounts.first { $0.id == id }?.hasPaidPlan == true
            return [paid ? ClaudeUsageError.usageNotProvided : ClaudeUsageError.notSubscribed]
        case .unsupported: return [ClaudeUsageError.unsupportedLocalRecord]
        case .ambiguous: return [ClaudeUsageError.ambiguousOrganization]
        }
    }

    // 원인이 바뀔 때만 계정 앞자리와 오류 종류를 기록하고 인증값·응답 본문은 남기지 않는다.
    private func recordIssues(_ issues: [any Error], id: String) {
        let summary = issues.map(Self.logDescription)
        if !summary.isEmpty, summary != (usageIssues[id] ?? []).map(Self.logDescription) {
            NSLog("CodexSwitch Claude usage unavailable: account=%@ reasons=%@", String(id.prefix(8)), summary.joined(separator: ", "))
        }
        usageIssues[id] = issues
    }

    // Claude에서 로그인한 뒤 새 세션만 보관하고 원래 활성 세션으로 돌아온다.
    func connectAccount() async throws -> String {
        await acquireMutation()
        defer { releaseMutation() }
        try await recoverIfNeeded()
        try await runtime.stop()
        try await requireStopped()
        let baseline = try captureSnapshot()
        var registry = try readRegistry()
        if let id = baseline.accountID {
            registerCurrent(id, in: &registry)
            try saveSnapshot(baseline, id: id)
        }
        try beginRecovery(baseline)
        do {
            try applySnapshot(Snapshot(auth: [:], cookies: [:]))
            guard try await runtime.open() else { throw ClaudeAuthError.appNotInstalled }
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: loginTimeout)
            var connected: (String, ClaudeProfile)?
            var lastLoginError: (any Error)?
            var deniedAttempts = 0
            var nextAttempt = Date.distantPast
            while clock.now < deadline {
                try Task.checkCancellation()
                do {
                    let auth = try readAuth()
                    if let id = auth.accountID, Date() >= nextAttempt {
                        let profile = try await desktopProfile(auth, id: id, liveCookies: true, interactive: true)
                        connected = (id, profile)
                        break
                    }
                } catch is CancellationError {
                    throw CancellationError()
                } catch ClaudeUsageError.keychainUnavailable {
                    throw ClaudeUsageError.keychainUnavailable
                } catch {
                    // 앱의 첫 로그인 저장 도중에는 JSON과 토큰이 서로 다른 시점에 완성될 수 있다.
                    lastLoginError = error
                    // 로그인은 끝났는데 조회만 계속 거부되면 제한 시간까지 기다리지 않고 원래 세션으로 돌아가 이유를 알린다.
                    if case ClaudeUsageError.accessDenied = error {
                        deniedAttempts += 1
                        if deniedAttempts >= 3 { throw error }
                    } else {
                        deniedAttempts = 0
                    }
                    if case let ClaudeUsageError.rateLimited(until) = error { nextAttempt = until }
                    else { nextAttempt = Date().addingTimeInterval(2) }
                }
                try await Task.sleep(for: pollInterval)
            }
            guard let (id, profile) = connected else { throw lastLoginError ?? ClaudeAuthError.loginTimedOut }
            try await stopIgnoringCancellation()
            try await requireStopped()
            let incoming = try captureSnapshot()
            guard incoming.accountID == id else { throw ClaudeAuthError.credentialChanged }
            try saveSnapshot(incoming, id: id)
            if let index = registry.accounts.firstIndex(where: { $0.id == id }) {
                registry.accounts[index].email = profile.email
                registry.accounts[index].plan = profile.plan
                blockedUntil[id] = nil
            } else {
                registry.accounts.append(Account(id: id, email: profile.email, name: nil, plan: profile.plan))
            }
            // 현재 설정은 유지하고 인증과 쿠키만 로그인 직전 값으로 복구한다.
            try applySnapshot(baseline)
            try writeRegistry(registry)
            try finishRecovery()
            _ = try? await runtime.open()
            return id
        } catch {
            let originalError = error
            do {
                try await stopIgnoringCancellation()
                try await requireStoppedIgnoringCancellation()
                try restoreRecovery()
            } catch {
                throw AccountServiceError.credentialRestoreFailed
            }
            _ = try? await runtime.open()
            throw originalError
        }
    }

    // 호출자가 Claude를 종료한 뒤에만 계정별 인증과 쿠키를 함께 교체한다.
    func switchAccount(accountKey: String) async throws {
        await acquireMutation()
        defer { releaseMutation() }
        try await recoverIfNeeded()
        try await requireStopped()
        var registry = try readRegistry()
        guard registry.accounts.contains(where: { $0.id == accountKey }) else { throw ClaudeAuthError.accountNotFound }
        let incoming = try readSnapshot(accountKey)
        guard incoming.accountID == accountKey else { throw ClaudeAuthError.invalidCredential }
        try await verifySavedIdentity(incoming, id: accountKey)
        try Task.checkCancellation()
        // 계정 확인이 네트워크나 키체인 승인을 기다리는 동안 Claude가 다시 열렸다면 쿠키를 교체하지 않는다.
        try await requireStopped()
        let baseline = try captureSnapshot()
        if let id = baseline.accountID {
            registerCurrent(id, in: &registry)
            try saveSnapshot(baseline, id: id)
        }
        try beginRecovery(baseline)
        do {
            try applySnapshot(incoming)
            try writeRegistry(registry)
            try finishRecovery()
        } catch {
            let originalError = error
            do { try restoreRecovery() } catch { throw AccountServiceError.credentialRestoreFailed }
            throw originalError
        }
    }

    // 비활성 계정 제거는 라이브 인증을 건드리지 않고, 활성 계정은 남은 프로필로 전환한다.
    func removeAccount(accountKey: String, expectedActive: Bool) async throws -> AccountRemovalResult {
        await acquireMutation()
        defer { releaseMutation() }
        try await recoverIfNeeded()
        var registry = try readRegistry()
        guard registry.accounts.contains(where: { $0.id == accountKey }) else { throw ClaudeAuthError.accountNotFound }
        let current = try readAuth().accountID
        guard (current == accountKey) == expectedActive else { throw ClaudeAuthError.credentialChanged }
        registry.accounts.removeAll { $0.id == accountKey }
        if expectedActive {
            try await requireStopped()
            let baseline = try captureSnapshot()
            // 저장된 로그인이 있는 첫 계정으로 전환하고, 복원할 계정이 없으면 이 Mac의 로그인만 해제한다.
            var incoming = Snapshot(auth: [:], cookies: [:])
            for account in registry.accounts {
                if let snapshot = try? readSnapshot(account.id) {
                    incoming = snapshot
                    break
                }
            }
            try beginRecovery(baseline)
            do {
                try applySnapshot(incoming)
                try writeRegistry(registry)
                try finishRecovery()
            } catch {
                let originalError = error
                do { try restoreRecovery() } catch { throw AccountServiceError.credentialRestoreFailed }
                throw originalError
            }
        } else {
            try writeRegistry(registry)
        }
        do {
            try removeIfPresent(snapshotURL(accountKey))
            return AccountRemovalResult(credentialCleanupComplete: true)
        } catch {
            return AccountRemovalResult(credentialCleanupComplete: false)
        }
    }

    func fetchResetCredits(accountKey: String) -> [ResetCredit] { [] }

    // 온라인에서 확인된 다른 계정은 거부하되, 만료된 조회 토큰은 앱 자체가 갱신하도록 둔다.
    private func verifySavedIdentity(_ snapshot: Snapshot, id: String) async throws {
        do {
            _ = try await desktopProfile(snapshot, id: id, liveCookies: false, interactive: true)
        } catch is CancellationError {
            throw CancellationError()
        } catch ClaudeUsageError.accountMismatch {
            throw ClaudeUsageError.accountMismatch
        } catch ClaudeUsageError.invalidCredential {
            throw ClaudeUsageError.invalidCredential
        } catch {
            // 네트워크·키체인이 없어도 같은 Mac에 저장된 데스크톱 세션은 복원할 수 있다.
        }
    }

    // Code OAuth가 아직 없거나 만료돼도 정상 데스크톱 로그인 쿠키로 계정을 확인한다.
    private func desktopProfile(_ snapshot: Snapshot, id: String, liveCookies: Bool, interactive: Bool) async throws -> ClaudeProfile {
        if let encrypted = snapshot.encryptedCache {
            do {
                return try await client.profile(encryptedCache: encrypted, expectedAccountID: id, allowKeychainPrompt: interactive)
            } catch {
                guard canUseWebSession(after: error) else { throw error }
            }
        }
        let (database, temporary) = try cookieDatabase(snapshot, live: liveCookies)
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        return try await webClient.profile(cookieDatabase: database, expectedAccountID: id, allowKeychainPrompt: interactive)
    }

    private func desktopReading(_ snapshot: Snapshot, id: String, liveCookies: Bool, interactive: Bool) async throws -> (profile: ClaudeProfile, usage: UsageSnapshot) {
        if let encrypted = snapshot.encryptedCache {
            do {
                return try await client.profileAndUsage(encryptedCache: encrypted, expectedAccountID: id, allowKeychainPrompt: interactive)
            } catch {
                guard canUseWebSession(after: error) else { throw error }
            }
        }
        let (database, temporary) = try cookieDatabase(snapshot, live: liveCookies)
        defer { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
        return try await webClient.profileAndUsage(cookieDatabase: database, expectedAccountID: id, allowKeychainPrompt: interactive,
                                                   preferredOrganizationID: desktopOrganizations[id.lowercased()])
    }

    // 계정 불일치·조회 제한·키체인 거부는 다른 인증 경로로 재시도하지 않는다.
    private func canUseWebSession(after error: any Error) -> Bool {
        switch error {
        case ClaudeUsageError.invalidCredential, ClaudeUsageError.tokenExpired, ClaudeUsageError.signedOut,
             ClaudeUsageError.accessDenied: true
        default: false
        }
    }

    // 비활성 계정 쿠키는 비공개 임시 폴더에서만 열고 조회 직후 제거한다.
    private func cookieDatabase(_ snapshot: Snapshot, live: Bool) throws -> (URL, URL?) {
        if live {
            let database = try cookieDirectory().appendingPathComponent("Cookies")
            try validatePath(database)
            try validateFile(database)
            return (database, nil)
        }
        guard snapshot.cookies["Cookies"]?.isEmpty == false else { throw ClaudeUsageError.invalidCredential }
        let directory = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("claude-session-\(UUID().uuidString)", isDirectory: true)
        do {
            for name in Self.cookieNames {
                if let data = snapshot.cookies[name] { try writePrivate(data, to: directory.appendingPathComponent(name)) }
            }
            return (directory.appendingPathComponent("Cookies"), directory)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    private func registerCurrent(_ id: String, in registry: inout Registry) {
        guard !registry.accounts.contains(where: { $0.id == id }) else { return }
        registry.accounts.append(Account(id: id, email: "Claude · \(id.prefix(8))"))
    }

    private func readRegistry() throws -> Registry {
        guard let data = try readIfPresent(registryURL) else { return Registry() }
        guard let registry = try? JSONDecoder().decode(Registry.self, from: data), registry.version == 1,
              Set(registry.accounts.map(\.id)).count == registry.accounts.count,
              registry.accounts.allSatisfy({ UUID(uuidString: $0.id) != nil }) else { throw ClaudeAuthError.invalidData }
        return registry
    }

    private func writeRegistry(_ registry: Registry) throws {
        try writePrivate(JSONEncoder().encode(registry), to: registryURL)
    }

    private func snapshotURL(_ id: String) throws -> URL {
        guard let uuid = UUID(uuidString: id) else { throw ClaudeAuthError.invalidCredential }
        return storageDirectory.appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent(uuid.uuidString.lowercased() + ".json")
    }

    private func saveSnapshot(_ snapshot: Snapshot, id: String) throws {
        guard snapshot.accountID == id else { throw ClaudeAuthError.invalidCredential }
        try writePrivate(JSONEncoder().encode(snapshot), to: snapshotURL(id))
    }

    private func readSnapshot(_ id: String) throws -> Snapshot {
        guard let data = try readIfPresent(snapshotURL(id)),
              let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data),
              snapshot.accountID == id,
              snapshot.encryptedCache?.isEmpty == false || snapshot.cookies["Cookies"]?.isEmpty == false else {
            throw ClaudeAuthError.snapshotNotFound
        }
        return snapshot
    }

    // 실행 중에는 인증 JSON만 읽고, 쿠키 스냅샷은 완전 종료 후에만 만든다.
    private func readAuth() throws -> Snapshot {
        let config = try readConfig()
        var auth: [String: Data] = [:]
        for key in Self.authKeys {
            if let value = config[key] {
                auth[key] = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
            }
        }
        return Snapshot(auth: auth, cookies: [:])
    }

    private func captureSnapshot() throws -> Snapshot {
        var snapshot = try readAuth()
        let base = try cookieDirectory()
        for name in Self.cookieNames {
            if let data = try readIfPresent(base.appendingPathComponent(name)) { snapshot.cookies[name] = data }
        }
        return snapshot
    }

    private func readConfig() throws -> [String: Any] {
        guard let data = try readIfPresent(configURL) else { return [:] }
        guard let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ClaudeAuthError.invalidData }
        return config
    }

    private func cookieDirectory() throws -> URL {
        let network = dataDirectory.appendingPathComponent("Network", isDirectory: true)
        if FileManager.default.fileExists(atPath: network.path) {
            try validatePath(network)
            return network
        }
        return dataDirectory
    }

    private func applySnapshot(_ snapshot: Snapshot) throws {
        guard Set(snapshot.auth.keys).isSubset(of: Set(Self.authKeys)),
              Set(snapshot.cookies.keys).isSubset(of: Set(Self.cookieNames)) else { throw ClaudeAuthError.invalidData }
        var config = try readConfig()
        for key in Self.authKeys {
            config[key] = try snapshot.auth[key].map { try JSONSerialization.jsonObject(with: $0, options: [.fragmentsAllowed]) }
        }
        let base = try cookieDirectory()
        for name in Self.cookieNames {
            let url = base.appendingPathComponent(name)
            if let data = snapshot.cookies[name] { try writePrivate(data, to: url) }
            else { try removeIfPresent(url) }
        }
        try writePrivate(JSONSerialization.data(withJSONObject: config, options: [.prettyPrinted, .sortedKeys]), to: configURL)
    }

    private func beginRecovery(_ snapshot: Snapshot) throws {
        let recovery = Recovery(snapshot: snapshot, registry: try readIfPresent(registryURL))
        try writePrivate(JSONEncoder().encode(recovery), to: recoveryURL)
    }

    private func finishRecovery() throws { try removeIfPresent(recoveryURL) }

    private func restoreRecovery() throws {
        guard let data = try readIfPresent(recoveryURL) else { return }
        let recovery = try JSONDecoder().decode(Recovery.self, from: data)
        try applySnapshot(recovery.snapshot)
        if let registry = recovery.registry { try writePrivate(registry, to: registryURL) }
        else { try removeIfPresent(registryURL) }
        try finishRecovery()
    }

    private func recoverIfNeeded() async throws {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        guard !(await runtime.isRunning()) else { throw ClaudeAuthError.unfinishedTransaction }
        do { try restoreRecovery() } catch { throw AccountServiceError.credentialRestoreFailed }
    }

    private func requireStopped() async throws {
        for _ in 0..<40 {
            if !(await runtime.isRunning()) { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw ClaudeAuthError.appRunning
    }

    private func stopIgnoringCancellation() async throws {
        let runtime = runtime
        try await Task { @MainActor in try await runtime.stop() }.value
    }

    private func requireStoppedIgnoringCancellation() async throws {
        try await Task { try await self.requireStopped() }.value
    }

    // macOS의 시스템 별칭만 허용하고 사용자 폴더 안의 심볼릭 링크는 따라가지 않는다.
    private func validatePath(_ url: URL) throws {
        var current = url.standardizedFileURL
        while current.path != "/" {
            if let attributes = try? FileManager.default.attributesOfItem(atPath: current.path),
               attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                let aliases = ["/var": "private/var", "/tmp": "private/tmp", "/etc": "private/etc"]
                guard let destination = aliases[current.path],
                      try FileManager.default.destinationOfSymbolicLink(atPath: current.path) == destination else {
                    throw ClaudeAuthError.unsafePath
                }
            }
            current.deleteLastPathComponent()
        }
    }

    private func readIfPresent(_ url: URL) throws -> Data? {
        try validatePath(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        try validateFile(url)
        return try Data(contentsOf: url)
    }

    private func removeIfPresent(_ url: URL) throws {
        try validatePath(url)
        if FileManager.default.fileExists(atPath: url.path) {
            try validateFile(url)
            try FileManager.default.removeItem(at: url)
        }
    }

    private func validateFile(_ url: URL) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else { throw ClaudeAuthError.unsafePath }
    }

    // 임시 파일부터 0600으로 작성하고 rename으로 적용해 인증 평문이나 부분 JSON을 남기지 않는다.
    private func writePrivate(_ data: Data, to url: URL) throws {
        try validatePath(url)
        if FileManager.default.fileExists(atPath: url.path) { try validateFile(url) }
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let temporary = parent.appendingPathComponent(".claude-switch-\(UUID().uuidString)")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard Darwin.rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func acquireMutation() async {
        if mutationInProgress { await withCheckedContinuation { mutationWaiters.append($0) } }
        else { mutationInProgress = true }
    }

    private func releaseMutation() {
        if mutationWaiters.isEmpty { mutationInProgress = false }
        else { mutationWaiters.removeFirst().resume() }
    }
}

// 인증 원문과 서버 응답 본문을 사용자 오류에 포함하지 않는다.
enum ClaudeAuthError: LocalizedError {
    case appNotInstalled, appRunning, invalidCredential, invalidData, unsafePath
    case accountNotFound, snapshotNotFound, accountAlreadyConnected, credentialChanged
    case loginTimedOut, unfinishedTransaction

    var errorDescription: String? {
        switch self {
        case .appNotInstalled: L10n.text("Claude 데스크톱 앱을 설치한 뒤 다시 시도해 주세요.")
        case .appRunning: L10n.text("Claude가 완전히 종료되지 않았습니다. 종료한 뒤 다시 시도해 주세요.")
        case .invalidCredential: L10n.text("Claude 인증을 확인하지 못했습니다. 계정을 다시 추가해 주세요.")
        case .invalidData: L10n.text("Claude 계정 정보를 읽지 못했습니다. 로컬 파일을 확인해 주세요.")
        case .unsafePath: L10n.text("Claude 인증 경로에 심볼릭 링크가 있어 작업을 중단했습니다.")
        case .accountNotFound: L10n.text("선택한 Claude 계정이 목록에서 사라졌습니다. 새로고침해 주세요.")
        case .snapshotNotFound: L10n.text("저장된 Claude 로그인이 없습니다. 계정을 다시 추가해 주세요.")
        case .accountAlreadyConnected: L10n.text("이미 추가된 계정입니다. 상단 계정 목록에서 선택해 주세요.")
        case .credentialChanged: L10n.text("Claude 로그인 상태가 변경됐습니다. 새로고침한 뒤 다시 시도해 주세요.")
        case .loginTimedOut: L10n.text("Claude 로그인 대기 시간이 지났습니다. 계정 추가를 다시 시도해 주세요.")
        case .unfinishedTransaction: L10n.text("이전 Claude 계정 작업을 복구해야 합니다. Claude를 종료한 뒤 새로고침해 주세요.")
        }
    }
}
