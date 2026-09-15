import AppKit
import Combine
import SwiftUI

// 창 배경을 흉내 내지 않고 NSMenu가 시스템의 블러·모서리·그림자를 그리게 한다.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: AccountStore
    private let updateStore: UpdateStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    private let contentItem = NSMenuItem()
    private let switchItem = NSMenuItem(title: "계정 변경", action: nil, keyEquivalent: "")
    private let removeItem = NSMenuItem(title: "계정 제거", action: nil, keyEquivalent: "")
    private let connectionItem = NSMenuItem(title: "계정 추가", action: nil, keyEquivalent: "")
    private var storeObservation: AnyCancellable?
    private(set) var settingsWindow: NSWindow?

    init(store: AccountStore, updateStore: UpdateStore) {
        self.store = store
        self.updateStore = updateStore
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        menu.addItem(contentItem)
        statusItem.button?.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "CodexSwitch")
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
        for (title, key, action) in [("설정…", ",", #selector(openSettings)), ("종료", "q", #selector(quit))] {
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
        storeObservation = store.objectWillChange.sink { [weak self] _ in
            RunLoop.main.perform(inModes: [.common]) { [weak self] in
                MainActor.assumeIsolated { self?.refreshAccountMenus() }
            }
        }
        Task { await store.loadLocalAccounts() }
    }

    // 메뉴 추적 중에는 프레임을 바꾸지 않고, 다음에 열 때 최신 내용의 높이를 반영한다.
    func menuWillOpen(_ menu: NSMenu) {
        refreshAccountMenus()
        guard menu === self.menu else { return }
        let content = MenuContentView(store: store, updateStore: updateStore)
        let measurement = NSHostingView(rootView: content)
        let availableHeight = max(100, (statusItem.button?.window?.screen?.visibleFrame.height ?? 800) - 180)
        let height = min(measurement.fittingSize.height, availableHeight)
        let hosting = NSHostingView(rootView:
            ScrollView(.vertical) { content }
                .frame(width: 372, height: height, alignment: .top)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 372, height: height)
        contentItem.view = hosting
    }

    // 하위 메뉴를 닫아도 상위 메뉴의 요약 뷰는 유지한다.
    func menuDidClose(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        contentItem.view = nil
    }

    // 계정 구성이 같으면 기존 항목을 유지해 새로고침 중에도 선택 추적을 보존한다.
    func refreshAccountMenus() {
        for (parent, action) in [(switchItem, #selector(switchAccount(_:))), (removeItem, #selector(removeAccount(_:)))] {
            guard let submenu = parent.submenu else { continue }
            // 비활성 부모 아래에서는 자식의 isEnabled도 false이므로 모델로 부모 상태를 먼저 결정한다.
            parent.isEnabled = !store.isBusy && store.accounts.contains {
                parent === removeItem || $0.account.accountKey != store.activeAccountKey
            }
            let keys = store.accounts.map { $0.account.accountKey }
            if submenu.items.compactMap({ $0.representedObject as? String }) != keys {
                submenu.removeAllItems()
                for key in keys {
                    let item = NSMenuItem(title: "", action: action, keyEquivalent: "")
                    item.target = self
                    item.representedObject = key
                    submenu.addItem(item)
                }
            }
            for (item, account) in zip(submenu.items, store.accounts) {
                let active = account.account.accountKey == store.activeAccountKey
                item.title = account.account.displayName
                item.toolTip = "\(account.account.email) · \(account.account.displayPlan)"
                item.state = active ? .on : .off
                item.isEnabled = !store.isBusy && (parent === removeItem || !active)
            }
        }
        connectionItem.title = store.isConnecting ? "추가 취소" : "계정 추가"
        connectionItem.isEnabled = !store.isBusy || store.isConnecting
    }

    // 오래 열린 메뉴의 계정 객체를 재사용하지 않고 최신 목록에서 대상을 확인한다.
    private func selectedAccount(_ sender: NSMenuItem) -> AccountListItem? {
        guard !store.isBusy, let key = sender.representedObject as? String else { return nil }
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
            guard SystemConfirmationAlert.present(
                title: "이 계정을 이 Mac에서 제거할까요?",
                message: removalMessage(for: item),
                confirmTitle: "제거",
                confirmIsDestructive: true
            ) else { return }
            store.removeAccount(item)
        }
    }

    @objc private func connectAccount() {
        guard !store.isBusy || store.isConnecting else { return }
        menu.cancelTracking()
        if store.isConnecting { store.cancelConnection() } else { store.connectAccount() }
    }

    private func removalMessage(for item: AccountListItem) -> String {
        let name = item.account.displayName
        let isActive = item.account.accountKey == store.activeAccountKey
        let localOnly = "ChatGPT 계정 자체는 삭제되지 않습니다."

        if isActive, store.accounts.count == 1 {
            return "“\(name)”은 마지막 계정입니다. 제거하면 ChatGPT를 닫고 이 Mac의 Codex 인증을 해제합니다. \(localOnly)"
        }
        if isActive {
            return "“\(name)”은 현재 사용 중인 계정입니다. 제거하면 ChatGPT를 안전하게 닫고 남은 계정으로 전환합니다. \(localOnly)"
        }
        return "이 Mac에 저장된 “\(name)”의 인증 정보만 제거합니다. \(localOnly)"
    }

    // 앱 수명과 함께 상태바 항목과 소유 창을 정리한다.
    func stop() {
        storeObservation?.cancel()
        menu.cancelTracking()
        settingsWindow?.close()
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // 독립 NSHostingView는 SwiftUI Scene의 openSettings 환경을 상속하지 않는다.
    @objc func openSettings() {
        guard !store.isRestartingForUpdate else { return }
        menu.cancelTracking()
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: SettingsView(updateStore: updateStore, accountStore: store))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "CodexSwitch 설정"
            window.isReleasedWhenClosed = false
            window.contentView = hosting
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        guard !store.isBusy else { return }
        menu.cancelTracking()
        store.quit()
    }
}
