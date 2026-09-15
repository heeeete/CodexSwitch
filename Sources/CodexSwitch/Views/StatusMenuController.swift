import AppKit
import SwiftUI

// 창 배경을 흉내 내지 않고 NSMenu가 시스템의 블러·모서리·그림자를 그리게 한다.
@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let store: AccountStore
    private let updateStore: UpdateStore
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    let menu = NSMenu()
    private let contentItem = NSMenuItem()
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

        // 사용자 정의 메뉴 뷰에는 키보드 이벤트가 전달되지 않으므로 메뉴 단축키를 등록한다.
        for (title, key, action) in [("설정…", ",", #selector(openSettings)), ("종료", "q", #selector(quit))] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            item.target = self
            item.isHidden = true
            item.allowsKeyEquivalentWhenHidden = true
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
        Task { await store.loadLocalAccounts() }
    }

    // 메뉴 추적 중에는 프레임을 바꾸지 않고, 다음에 열 때 최신 내용의 높이를 반영한다.
    func menuWillOpen(_ menu: NSMenu) {
        let content = MenuContentView(store: store, updateStore: updateStore, showSettings: { [weak self] in
            self?.openSettings()
        })
        let measurement = NSHostingView(rootView: content)
        let availableHeight = (statusItem.button?.window?.screen?.visibleFrame.height ?? 800) - 24
        let height = min(measurement.fittingSize.height, availableHeight)
        let hosting = NSHostingView(rootView:
            ScrollView(.vertical) { content }
                .frame(width: 372, height: height, alignment: .top)
        )
        hosting.frame = NSRect(x: 0, y: 0, width: 372, height: height)
        contentItem.view = hosting
    }

    // 메뉴가 닫히면 hover 팝업과 SwiftUI 작업도 함께 정리한다.
    func menuDidClose(_ menu: NSMenu) {
        contentItem.view = nil
    }

    // 앱 수명과 함께 상태바 항목과 소유 창을 정리한다.
    func stop() {
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
