import AppKit

// 안정적인 부모 창이 없는 메뉴바 앱의 확인 작업은 독립적인 app-modal alert로 처리한다.
@MainActor
enum SystemConfirmationAlert {
    static func present(
        title: String,
        message: String,
        confirmTitle: String,
        confirmIsDestructive: Bool = false,
        cancelTitle: String = "취소",
        runModal: ((NSAlert) -> NSApplication.ModalResponse)? = nil
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message

        // 첫 번째 버튼을 확인 응답으로 고정해 runModal 반환값과 직접 대응시킨다.
        let confirmButton = alert.addButton(withTitle: confirmTitle)
        confirmButton.hasDestructiveAction = confirmIsDestructive
        alert.addButton(withTitle: cancelTitle)

        let response = runModal?(alert) ?? alert.runModal()
        return response == .alertFirstButtonReturn
    }
}
