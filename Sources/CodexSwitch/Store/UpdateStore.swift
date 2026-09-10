import AppKit
import Combine
import Sparkle

// Sparkle가 검증한 업데이트 상태와 메뉴 하단의 설치 동작을 연결한다.
@MainActor
final class UpdateStore: NSObject, ObservableObject, SPUUpdaterDelegate {
    enum Status {
        case idle, available, preparing, ready, installing, failed
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var automaticallyChecksForUpdates = true
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var checkMessage = ""
    private var observations = Set<AnyCancellable>()
    private var pendingAction: (() -> Void)?
    private var updater: SPUUpdater?
    private lazy var userDriver = UpdateUserDriver(store: self)
    private let prepareForRestart: () -> Bool
    private let restartCancelled: () -> Void

    init(
        startAutomatically: Bool = false,
        prepareForRestart: @escaping () -> Bool = { true },
        restartCancelled: @escaping () -> Void = {}
    ) {
        self.prepareForRestart = prepareForRestart
        self.restartCancelled = restartCancelled
        super.init()
        if startAutomatically { start() }
    }

    var message: String {
        switch status {
        case .idle: return ""
        case .available: return "새로운 업데이트가 있어요!"
        case .preparing: return "업데이트를 준비하고 있어요."
        case .ready: return "새로운 업데이트가 있어요! 다시 시작할까요?"
        case .installing: return "업데이트하고 다시 시작할게요."
        case .failed: return "업데이트를 준비하지 못했어요. 다시 시도할까요?"
        }
    }

    var actionTitle: String? {
        switch status {
        case .available: return "업데이트"
        case .ready: return "다시 시작"
        case .failed: return "다시 시도"
        default: return nil
        }
    }

    // 시작 시 한 번만 구성하고 이후 확인 주기와 다운로드는 Sparkle에 맡긴다.
    func start() {
        guard updater == nil else { return }
        let updater = SPUUpdater(
            hostBundle: .main, applicationBundle: .main,
            userDriver: userDriver, delegate: self
        )
        self.updater = updater
        // 자동 확인 설정은 Sparkle가 저장하고, 예약 상태 변경도 같은 값을 관찰한다.
        updater.publisher(for: \.automaticallyChecksForUpdates)
            .sink { [weak self] in self?.automaticallyChecksForUpdates = $0 }
            .store(in: &observations)
        updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] in self?.canCheckForUpdates = $0 }
            .store(in: &observations)
        do {
            try updater.start()
        } catch {
            showFailure(error)
        }
    }

    // 설정을 꺼도 사용자가 누르는 수동 확인은 계속 사용할 수 있다.
    func setAutomaticallyChecksForUpdates(_ enabled: Bool) {
        updater?.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard let updater, updater.canCheckForUpdates,
              status == .idle || status == .failed else { return }
        status = .idle
        updater.checkForUpdates()
    }

    // 계정 작업이 끝난 상태에서만 설치를 시작하고, 반복 클릭은 한 번만 처리한다.
    func performAction() {
        if status == .failed {
            guard let updater, updater.canCheckForUpdates else { return }
            status = .idle
            updater.checkForUpdatesInBackground()
            return
        }
        guard let action = pendingAction else { return }
        if status == .ready {
            guard prepareForRestart() else { return }
            status = .installing
        } else {
            status = .preparing
        }
        pendingAction = nil
        action()
    }

    // 자동 다운로드·검증이 끝나면 앱을 종료하지 않고 사용자의 재시작 선택을 기다린다.
    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock: @escaping () -> Void
    ) -> Bool {
        offerUpdate(ready: true, action: immediateInstallationBlock)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        // 연결 실패나 최신 버전 확인처럼 조용히 끝난 백그라운드 조회는 메뉴에 남기지 않는다.
        if status != .idle { showFailure(error) }
    }

    fileprivate func offerUpdate(ready: Bool, action: @escaping () -> Void) {
        checkMessage = ""
        pendingAction = action
        status = ready ? .ready : .available
    }

    fileprivate func showPreparing() {
        checkMessage = ""
        pendingAction = nil
        status = .preparing
    }

    fileprivate func showInstalling() {
        status = .installing
    }

    fileprivate func showFailure(_ error: Error) {
        NSLog("CodexSwitch update failed: %@", error.localizedDescription)
        pendingAction = nil
        checkMessage = ""
        restartCancelled()
        status = .failed
    }

    // 수동 조회의 진행·최신 버전 안내는 설정 창에서만 표시한다.
    fileprivate func showChecking() {
        checkMessage = "업데이트를 확인하고 있어요."
    }

    fileprivate func showUpToDate() {
        dismiss()
        checkMessage = "최신 버전을 사용하고 있어요."
    }

    fileprivate func dismiss() {
        pendingAction = nil
        if status != .failed {
            restartCancelled()
            status = .idle
        }
    }
}

// 버전 번호가 나오는 기본 창 대신 같은 메뉴 안에서 업데이트를 안내한다.
@MainActor
final class UpdateUserDriver: NSObject, SPUUserDriver {
    private weak var store: UpdateStore?

    init(store: UpdateStore) { self.store = store }

    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        // 앱의 Info.plist에서 자동 확인을 기본 제공하며 시스템 정보는 전송하지 않는다.
        reply(SUUpdatePermissionResponse(automaticUpdateChecks: true, sendSystemProfile: false))
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        // 설치 대신 웹 안내만 제공하는 긴급 배포도 잘못 설치하지 않는다.
        if appcastItem.isInformationOnlyUpdate {
            store?.offerUpdate(ready: false) {
                if let url = appcastItem.infoURL { NSWorkspace.shared.open(url) }
                reply(.dismiss)
            }
            return
        }
        // 관리자 인증이 필요한 경우에는 버튼을 누른 뒤에만 설치를 재개한다.
        store?.offerUpdate(ready: state.stage == .installing) { reply(.install) }
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        store?.offerUpdate(ready: true) { reply(.install) }
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        store?.showChecking()
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        store?.showPreparing()
    }

    func showDownloadDidStartExtractingUpdate() { store?.showPreparing() }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        store?.showInstalling()
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        store?.showFailure(error)
        acknowledgement()
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        store?.showUpToDate()
        acknowledgement()
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        store?.dismiss()
        acknowledgement()
    }

    func dismissUpdateInstallation() { store?.dismiss() }

    // 메뉴에는 준비 중 상태만 표시하므로 세부 진행률과 릴리스 노트 창은 사용하지 않는다.
    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {}
    func showDownloadDidReceiveData(ofLength length: UInt64) {}
    func showExtractionReceivedProgress(_ progress: Double) {}
    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {}
    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {}
}
