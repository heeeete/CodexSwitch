import AppKit
import Combine
import SwiftUI

// 창 배경을 흉내 내지 않고 NSMenu가 시스템의 블러·모서리·그림자를 그리게 한다.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let accounts: ProviderAccounts
    private var store: AccountStore { accounts.selectedStore }
    private let updateStore: UpdateStore
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    private let contentItem = NSMenuItem()
    private let switchItem = NSMenuItem(title: L10n.text("계정 변경"), action: nil, keyEquivalent: "")
    private let removeItem = NSMenuItem(title: L10n.text("계정 제거"), action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: L10n.text("계정 추가"), action: nil, keyEquivalent: "")
    private var storeObservation: AnyCancellable?
    private var languageObservation: AnyCancellable?
    private var displayTimer: Timer?
    private(set) var settingsWindow: NSWindow?

    // 기존 단일 Store 호출은 Codex 탭으로 시작해 저장된 서비스 선택의 영향을 받지 않는다.
    convenience init(store: AccountStore, updateStore: UpdateStore) {
        self.init(accounts: ProviderAccounts(codex: store, initialProvider: .codex), updateStore: updateStore)
    }

    init(accounts: ProviderAccounts, updateStore: UpdateStore) {
        self.accounts = accounts
        self.updateStore = updateStore
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(contentItem)
        statusItem.button?.image = CodexSwitchIcon.menuBarImage
        statusItem.button?.imagePosition = .imageLeft
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        statusItem.menu = menu

        // 계정 명령은 실제 메뉴 항목으로 만들어 하위 메뉴 추적을 macOS에 맡긴다.
        menu.addItem(.separator())
        for (item, symbol) in [(switchItem, "person.2"), (connectionItem, "person.badge.plus"), (removeItem, "person.badge.minus")] {
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: item.title)
            menu.addItem(item)
        }
        for item in [switchItem, removeItem] {
            let submenu = NSMenu(title: item.title)
            submenu.autoenablesItems = false
            submenu.delegate = self
            item.submenu = submenu
        }
        connectionItem.target = self
        connectionItem.action = #selector(connectAccount)
        menu.addItem(.separator())
        // 메뉴 단축키와 클릭은 같은 실행 시점의 상태 검사를 공유한다.
        for (title, key, action) in [(L10n.text("설정…"), ",", #selector(openSettings)), (L10n.text("종료"), "q", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.image = NSImage(systemSymbolName: key == "," ? "gearshape" : "power", accessibilityDescription: title)
            menu.addItem(item)
        }
        // 설정 창의 앱 메뉴도 같은 액션을 사용하고, 작업 가능 여부는 실행 순간에 확인한다.
        let applicationMenu = NSMenu()
        applicationMenu.autoenablesItems = false
        for item in menu.items where !item.keyEquivalent.isEmpty {
            let command = NSMenuItem(title: item.title, action: item.action, keyEquivalent: item.keyEquivalent)
            command.target = self
            applicationMenu.addItem(command)
        }
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        applicationItem.submenu = applicationMenu
        mainMenu.addItem(applicationItem)
        NSApp.mainMenu = mainMenu
        refreshAccountMenus()
        // Published 값이 반영된 다음, 메뉴 추적 중에도 명령의 활성 상태를 갱신한다.
        storeObservation = accounts.objectWillChange.sink { [weak self] _ in
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.refreshAccountMenus() }
            }
        }
        // 메뉴 객체와 열린 설정 창의 제목도 언어 저장 직후 같은 상태로 갱신한다.
        languageObservation = LanguageSettings.shared.$selection.dropFirst().sink { [weak self] _ in
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.refreshAccountMenus() }
            }
        }
        // 자동 조회를 꺼도 경과 시각과 만료 표시는 갱신하며 네트워크 요청은 하지 않는다.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccountMenus() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        displayTimer = timer
        Task { await accounts.selectedStore.loadLocalAccounts() }
    }

    // 열 때 현재 탭의 높이로 시작하고, 열려 있는 동안에도 내용이 바뀌면 메뉴 높이를 따라 맞춘다.
    func menuWillOpen(_ menu: NSMenu) {
        refreshAccountMenus()
        guard menu === self.menu else { return }
        let content = ProviderMenuContentView(accounts: accounts, updateStore: updateStore)
            // 안내가 뜨거나 닫히고 탭이 바뀌면 그만큼 메뉴를 늘리고 줄여 내부 스크롤과 빈 공간을 만들지 않는다.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { [weak self] height in
                self?.resizeContent(to: height)
            }
        // 화면보다 긴 내용만 스크롤하도록 뷰포트는 호스팅 뷰의 크기를 그대로 따른다.
        let hosting = NSHostingView(rootView: ScrollView(.vertical) { content }.frame(width: 372))
        hosting.sizingOptions = []
        let contentHeight = NSHostingView(rootView: MenuContentView(store: store, updateStore: updateStore)).fittingSize.height
        hosting.frame = NSRect(x: 0, y: 0, width: 372, height: min(contentHeight, availableContentHeight))
        contentItem.view = hosting
    }

    // 메뉴가 화면을 넘지 않도록 하는 높이 한도이며, 낮은 화면에서는 이 높이부터 안쪽을 스크롤한다.
    var availableContentHeight: CGFloat {
        max(100, (statusItem.button?.window?.screen?.visibleFrame.height ?? 800) - 180)
    }

    // 항목 뷰의 프레임이 바뀌면 열려 있는 NSMenu도 같은 높이로 다시 배치된다.
    private func resizeContent(to contentHeight: CGFloat) {
        guard let view = contentItem.view else { return }
        let height = min(contentHeight, availableContentHeight)
        guard abs(view.frame.height - height) > 0.5 else { return }
        view.setFrameSize(NSSize(width: 372, height: height))
    }

    // 하위 메뉴를 닫아도 상위 메뉴의 요약 뷰는 유지한다.
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        contentItem.view = nil
    }

    // 계정 구성이 같으면 기존 항목을 유지해 새로고침 중에도 선택 추적을 보존한다.
    func refreshAccountMenus() {
        switchItem.title = L10n.text("계정 변경")
        removeItem.title = L10n.text("계정 제거")
        switchItem.submenu?.title = switchItem.title
        removeItem.submenu?.title = removeItem.title
        for commandMenu in [menu, NSApp.mainMenu?.items.first?.submenu].compactMap({ $0 }) {
            for item in commandMenu.items {
                if item.keyEquivalent == "," { item.title = L10n.text("설정…") }
                if item.keyEquivalent == "q" { item.title = L10n.text("종료") }
            }
        }
        settingsWindow?.title = L10n.text("CodexSwitch 설정")
        let now = Date()
        let summaries = Dictionary(uniqueKeysWithValues: store.accounts.map {
            ($0.account.accountKey, AccountUsageSummary(account: $0.account, now: now))
        })
        // 현재 계정만 메뉴바에 표시하고, 연결 계정이 없으면 로고만 남긴다.
        if let active = store.accounts.first(where: { $0.account.accountKey == store.activeAccountKey }),
           let summary = summaries[active.account.accountKey] {
            // 숫자가 어느 서비스의 사용량인지 선택한 탭의 서비스 아이콘과 읽기 문구로 알린다.
            statusItem.button?.image = CodexSwitchIcon.menuBarImage(for: store.provider)
            statusItem.button?.title = " " + summary.menuBarText
            statusItem.button?.toolTip = "\(active.account.displayName)\n\(summary.menuText)"
            statusItem.button?.setAccessibilityLabel("CodexSwitch, \(store.provider.title), \(summary.menuText)")
        } else {
            // 숫자 없이 서비스 아이콘만 남으면 그 앱의 메뉴바 아이콘과 헷갈리므로 CodexSwitch 로고로 둔다.
            statusItem.button?.image = CodexSwitchIcon.menuBarImage
            statusItem.button?.title = ""
            statusItem.button?.toolTip = L10n.text("CodexSwitch · 현재 계정 없음")
            statusItem.button?.setAccessibilityLabel(L10n.text("CodexSwitch, 현재 계정 없음"))
        }
        for (parent, action) in [(switchItem, #selector(switchAccount(_:))), (removeItem, #selector(removeAccount(_:)))] {
            guard let submenu = parent.submenu else { continue }
            // 비활성 부모 아래에서는 자식의 isEnabled도 false이므로 모델로 부모 상태를 먼저 결정한다.
            parent.isEnabled = !accounts.isAccountOperationBusy && store.accounts.contains {
                parent === removeItem || $0.account.accountKey != store.activeAccountKey
            }
            let keys = store.accounts.map { $0.account.accountKey }
            // 서비스가 달라지면 같은 account key여도 메뉴 항목을 다시 만든다.
            let providerIdentifier = NSUserInterfaceItemIdentifier(accounts.selectedProvider.rawValue)
            if submenu.items.compactMap({ $0.representedObject as? String }) != keys
                || submenu.items.contains(where: { $0.identifier != providerIdentifier }) {
                submenu.removeAllItems()
                for key in keys {
                    let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
                    item.target = self
                    item.representedObject = key
                    item.identifier = providerIdentifier
                    submenu.addItem(item)
                }
            }
            for (item, account) in zip(submenu.items, store.accounts) {
                let active = account.account.accountKey == store.activeAccountKey
                let usage = summaries[account.account.accountKey]?.menuText ?? L10n.text("사용량 정보 없음")
                item.title = "\(account.account.displayName)    \(usage)"
                // 현재 계정이 아니어도 사용량이 비어 있는 이유를 항목 설명에서 확인할 수 있게 한다.
                item.toolTip = (["\(account.account.email) · \(account.account.displayPlan)", usage]
                    + account.account.usageIssues.map(\.localizedDescription)).joined(separator: "\n")
                item.state = active ? .on : .off
                item.isEnabled = !accounts.isAccountOperationBusy && (parent === removeItem || !active)
            }
        }
        connectionItem.title = store.isConnecting ? L10n.text("추가 취소") : L10n.text("계정 추가")
        connectionItem.isEnabled = !accounts.isAccountOperationBusy || store.isConnecting
    }

    // 오래 열린 메뉴의 계정 객체를 재사용하지 않고 최신 목록에서 대상을 확인한다.
    private func selectedAccount(_ sender: NSMenuItem) -> AccountListItem? {
        guard !accounts.isAccountOperationBusy,
              sender.identifier?.rawValue == accounts.selectedProvider.rawValue,
              sender.menu === switchItem.submenu || sender.menu === removeItem.submenu,
              let key = sender.representedObject as? String else { return nil }
        return store.accounts.first { $0.account.accountKey == key }
    }

    @objc private func switchAccount(_ sender: NSMenuItem) {
        guard let item = selectedAccount(sender), item.account.accountKey != store.activeAccountKey else { return }
        menu.cancelTracking()
        store.switchAccount(to: item)
    }

    // 메뉴 선택이 끝난 뒤 기존 제거 확인창과 안전한 인증 제거 흐름을 실행한다.
    @objc private func removeAccount(_ sender: NSMenuItem) {
        guard selectedAccount(sender) != nil else { return }
        menu.cancelTracking()
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self, let item = selectedAccount(sender) else { return }
            let selectedStore = store
            guard SystemConfirmationAlert.present(
                title: L10n.text("이 계정을 이 Mac에서 제거할까요?"),
                message: removalMessage(for: item),
                confirmTitle: L10n.text("제거"),
                confirmIsDestructive: true
            ) else { return }
            guard accounts.selectedStore === selectedStore, !accounts.isAccountOperationBusy else { return }
            selectedStore.removeAccount(item)
        }
    }

    @objc private func connectAccount() {
        guard !accounts.isAccountOperationBusy || store.isConnecting else { return }
        menu.cancelTracking()
        if store.isConnecting { store.cancelConnection() } else { store.connectAccount() }
    }

    private func removalMessage(for item: AccountListItem) -> String {
        let name = item.account.displayName
        let isActive = item.account.accountKey == store.activeAccountKey
        let localOnly = store.provider == .codex
            ? L10n.text("ChatGPT 계정 자체는 삭제되지 않습니다.")
            : L10n.text("Claude 계정 자체는 삭제되지 않습니다.")

        if isActive, store.accounts.count == 1 {
            return store.provider == .codex
                ? L10n.text("“%@”은 마지막 계정입니다. 제거하면 ChatGPT를 닫고 이 Mac의 Codex 인증을 해제합니다. %@", String(name), String(localOnly))
                : L10n.text("“%@”은 마지막 계정입니다. 제거하면 Claude를 닫고 이 Mac의 Claude 인증을 해제합니다. %@", String(name), String(localOnly))
        }
        if isActive {
            return store.provider == .codex
                ? L10n.text("“%@”은 현재 사용 중인 계정입니다. 제거하면 ChatGPT를 안전하게 닫고 남은 계정으로 전환합니다. %@", String(name), String(localOnly))
                : L10n.text("“%@”은 현재 사용 중인 계정입니다. 제거하면 Claude를 안전하게 닫고 남은 계정으로 전환합니다. %@", String(name), String(localOnly))
        }
        return L10n.text("이 Mac에 저장된 “%@”의 인증 정보만 제거합니다. %@", String(name), String(localOnly))
    }

    // 앱 수명과 함께 상태바 항목과 소유 창을 정리한다.
    func stop() {
        languageObservation?.cancel()
        displayTimer?.invalidate()
        storeObservation?.cancel()
        menu.cancelTracking()
        settingsWindow?.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // 독립 NSHostingView는 SwiftUI Scene의 openSettings 환경을 상속하지 않는다.
    @objc func openSettings() {
        guard !accounts.isRestartingForUpdate else { return }
        menu.cancelTracking()
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: ProviderSettingsView(updateStore: updateStore, accounts: accounts))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = L10n.text("CodexSwitch 설정")
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        guard !accounts.isBusy else { return }
        menu.cancelTracking()
        store.quit()
    }
}
