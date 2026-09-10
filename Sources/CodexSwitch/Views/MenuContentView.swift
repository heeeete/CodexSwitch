import SwiftUI

// 메뉴바 창 전체를 구성하고 상태별 화면을 분기한다.
struct MenuContentView: View {
    private enum AccountPopoverKind: Equatable {
        case switchAccount
        case removeAccount
    }

    @ObservedObject var store: AccountStore
    @Environment(\.colorScheme) private var colorScheme
    @State private var refreshIsHovered = false
    @State private var autoRefreshRowIsHovered = false
    @State private var restartRowIsHovered = false
    @State private var directAPIRowIsHovered = false
    @State private var presentedAccountPopover: AccountPopoverKind?
    @State private var hoveredAccountPopoverRow: AccountPopoverKind?
    @State private var hoveredAccountPopover: AccountPopoverKind?
    @State private var accountPopoverSuppressesHover = false
    @State private var accountPopoverCloseTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            header

            sectionDivider
                .padding(.horizontal, 12)

            content

            sectionDivider
                .padding(.horizontal, 12)

            footer
        }
        .frame(width: 372)
        .background(.regularMaterial)
        .task {
            await store.loadLocalAccounts()
        }
        .onChange(of: store.isBusy) { _, isBusy in
            if isBusy {
                dismissAccountPopover()
            }
        }
        .onChange(of: store.accounts.map(\.id)) { _, accountIDs in
            if accountIDs.isEmpty {
                dismissAccountPopover()
            } else if presentedAccountPopover == .switchAccount,
                      !hasAccountSwitchTarget {
                dismissAccountPopover()
            }
        }
        .onDisappear {
            dismissAccountPopover()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            CodexSwitchIconView(size: 32)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("CodexSwitch")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))

                Text(headerSubtitle)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(CodexSwitchDesign.secondaryText(for: colorScheme))
            }

            Spacer()

            Button {
                if store.isRefreshing {
                    store.cancelRefresh()
                } else {
                    store.refresh()
                }
            } label: {
                if store.isRefreshing {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 13, weight: .semibold))
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                }
            }
            .buttonStyle(.borderless)
            .frame(width: 28, height: 28)
            .background(
                refreshIsHovered
                    ? CodexSwitchDesign.hoverBackground(for: colorScheme)
                    : Color.clear,
                in: Circle()
            )
            .onHover { hovering in
                refreshIsHovered = hovering
            }
            .disabled((store.isBusy && !store.isRefreshing) || store.accounts.isEmpty)
            .help(
                store.isRefreshing
                    ? "사용량 새로 고침 취소"
                    : store.directAPIRefreshEnabled
                        ? "실험적 API로 사용량 새로 고침"
                        : "로컬 사용량 새로 고침"
            )
            .accessibilityLabel(store.isRefreshing ? "사용량 새로 고침 취소" : "사용량 새로 고침")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
    }

    @ViewBuilder
    private var content: some View {
        if store.accounts.isEmpty {
            emptyState
        } else {
            VStack(spacing: 0) {
                if let notice = store.notice {
                    NoticeBanner(notice: notice) {
                        store.dismissNotice()
                    }
                    .id(notice.id)
                }

                AccountOverview(
                    accounts: store.accounts,
                    activeAccountKey: store.activeAccountKey,
                    switchingAccountKey: store.switchingAccountKey,
                    removingAccountKey: store.removingAccountKey,
                    isDisabled: store.isBusy
                )
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            if store.isLoading {
                ProgressView()
                    .controlSize(.small)
                Text("계정 불러오는 중")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(CodexSwitchDesign.secondaryText(for: colorScheme))
            } else {
                Image(systemName: "person.2.slash")
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(CodexSwitchDesign.secondaryText(for: colorScheme))

                Text("저장된 계정이 없습니다")
                    .font(.system(size: 14, weight: .semibold, design: .rounded))

                Text("아래의 ‘계정 추가’를 눌러\nChatGPT 계정을 추가해 주세요.")
                    .font(.system(size: 12))
                    .foregroundStyle(CodexSwitchDesign.secondaryText(for: colorScheme))
                    .multilineTextAlignment(.center)
            }

            if let notice = store.notice {
                Text(notice.message)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(noticeTextColor(for: notice.style))
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 210)
        .padding(20)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            VStack(spacing: 0) {
                // 자동 갱신 주기를 기존 계정 변경 설정 바로 위에서 켜고 끈다.
                HStack(spacing: 8) {
                    Text("자동 새로고침")
                        .font(.system(size: 11, weight: .medium))

                    Text("1분마다")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(CodexSwitchDesign.smallText(for: colorScheme))

                    Spacer()

                    Toggle("자동 새로고침", isOn: $store.autoRefreshEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .frame(minHeight: 34)
                .padding(.horizontal, 9)
                .background(
                    autoRefreshRowIsHovered
                        ? CodexSwitchDesign.hoverBackground(for: colorScheme)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .onHover { hovering in
                    autoRefreshRowIsHovered = hovering
                }
                .help("메뉴를 닫아도 1분마다 현재 조회 설정으로 사용량을 새로 고칩니다.")

                sectionDivider
                    .padding(.leading, 10)

                HStack(spacing: 8) {
                    Text("변경 후 ChatGPT 열기")
                        .font(.system(size: 11, weight: .medium))

                    Spacer()

                    Toggle("", isOn: $store.restartChatGPTAfterSwitch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .frame(minHeight: 34)
                .padding(.horizontal, 9)
                .background(
                    restartRowIsHovered
                        ? CodexSwitchDesign.hoverBackground(for: colorScheme)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .onHover { hovering in
                    restartRowIsHovered = hovering
                }
                .help("안전한 계정 변경을 위해 실행 중인 ChatGPT는 항상 먼저 닫습니다.")

                sectionDivider
                    .padding(.leading, 10)

                HStack(spacing: 8) {
                    Text("실험적 API 조회")
                        .font(.system(size: 11, weight: .medium))

                    Text(store.directAPIRefreshEnabled ? "직접 API · 시각 확인" : "안전한 로컬 조회")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(
                            store.directAPIRefreshEnabled
                                ? CodexSwitchDesign.warningText(for: colorScheme)
                                : CodexSwitchDesign.smallText(for: colorScheme)
                        )
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Toggle(
                        "",
                        isOn: Binding(
                            get: { store.directAPIRefreshEnabled },
                            set: { store.setDirectAPIRefreshEnabled($0) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .disabled(store.isBusy)
                }
                .frame(minHeight: 34)
                .padding(.horizontal, 9)
                .background(
                    directAPIRowIsHovered && !store.isBusy
                        ? CodexSwitchDesign.hoverBackground(for: colorScheme)
                        : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .onHover { hovering in
                    directAPIRowIsHovered = hovering
                }
                .help("비공개 ChatGPT 사용량·워크스페이스 API를 사용하며 계정 제한 위험이 있습니다.")
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)

            sectionDivider
                .padding(.horizontal, 8)

            VStack(spacing: 0) {
                accountSwitchRow

                sectionDivider
                    .padding(.leading, 10)

                accountConnectionRow

                sectionDivider
                    .padding(.leading, 10)

                accountRemovalRow

                sectionDivider
                    .padding(.leading, 10)

                quitRow
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 5)
        }
    }

    // 계정 변경은 제거와 같은 hover 팝업에서 대상을 바로 선택한다.
    private var accountSwitchRow: some View {
        MenuCommandRow(
            isDisabled: store.isBusy || !hasAccountSwitchTarget,
            action: { presentAccountPopover(.switchAccount) }
        ) {
            MenuCommandLabel(
                title: "계정 변경",
                systemImage: "person.2",
                trailingSystemImage: "chevron.right"
            )
        }
        .onHover { hovering in
            setAccountPopoverRowHovered(.switchAccount, hovering: hovering)
        }
        .popover(
            isPresented: accountPopoverBinding(for: .switchAccount),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .leading
        ) {
            AccountPickerPopover(
                action: .switchAccount,
                accounts: store.accounts,
                activeAccountKey: store.activeAccountKey,
                isDisabled: store.isBusy,
                selectAction: selectAccountForSwitch
            )
            .onHover { hovering in
                setAccountPopoverHovered(.switchAccount, hovering: hovering)
            }
            .onDisappear {
                clearHoveredAccountPopover(.switchAccount)
            }
        }
        .help("계정 목록을 열어 변경할 계정 선택")
    }

    // 계정 추가는 다른 메뉴 명령과 같은 기준선과 hover 영역을 사용한다.
    private var accountConnectionRow: some View {
        MenuCommandRow(
            isDisabled: store.isBusy && !store.isConnecting,
            action: {
                if store.isConnecting {
                    store.cancelConnection()
                } else {
                    store.connectAccount()
                }
            }
        ) {
            if store.isConnecting {
                MenuCommandLabel(title: "추가 취소", systemImage: "xmark.circle")
            } else {
                MenuCommandLabel(
                    title: "계정 추가",
                    systemImage: "person.badge.plus",
                    trailingSystemImage: "chevron.right"
                )
            }
        }
        .help(store.isConnecting ? "ChatGPT 계정 추가 취소" : "새 ChatGPT 계정 추가")
    }

    // 제거도 같은 계정 팝업을 사용하고 선택 뒤 기존 확인창으로 넘긴다.
    private var accountRemovalRow: some View {
        MenuCommandRow(
            isDisabled: store.isBusy || store.accounts.isEmpty,
            action: { presentAccountPopover(.removeAccount) }
        ) {
            MenuCommandLabel(
                title: "계정 제거",
                systemImage: "person.badge.minus",
                trailingSystemImage: "chevron.right"
            )
        }
        .onHover { hovering in
            setAccountPopoverRowHovered(.removeAccount, hovering: hovering)
        }
        .popover(
            isPresented: accountPopoverBinding(for: .removeAccount),
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .leading
        ) {
            AccountPickerPopover(
                action: .removeAccount,
                accounts: store.accounts,
                activeAccountKey: store.activeAccountKey,
                isDisabled: store.isBusy,
                selectAction: selectAccountForRemoval
            )
            .onHover { hovering in
                setAccountPopoverHovered(.removeAccount, hovering: hovering)
            }
            .onDisappear {
                clearHoveredAccountPopover(.removeAccount)
            }
        }
        .help("계정 목록을 열어 제거할 계정 선택")
    }

    private var quitRow: some View {
        MenuCommandRow(isDisabled: store.isBusy, action: store.quit) {
            MenuCommandLabel(title: "종료", systemImage: "power", trailingText: "⌘Q")
        }
        .keyboardShortcut("q", modifiers: .command)
        .help("CodexSwitch 종료")
    }

    private var headerSubtitle: String {
        guard !store.accounts.isEmpty else { return "연결된 계정 없음" }
        return "계정 \(store.accounts.count)개"
    }

    private var sectionDivider: some View {
        Rectangle()
            .fill(CodexSwitchDesign.hairline(for: colorScheme))
            .frame(height: 1)
    }

    // 활성 계정이 없을 때는 저장 계정 하나만 있어도 최초 선택 대상으로 인정한다.
    private var hasAccountSwitchTarget: Bool {
        store.accounts.contains {
            $0.account.accountKey != store.activeAccountKey
        }
    }

    private func accountPopoverBinding(for kind: AccountPopoverKind) -> Binding<Bool> {
        Binding(
            get: { presentedAccountPopover == kind },
            set: { isPresented in
                if isPresented {
                    presentedAccountPopover = kind
                } else if presentedAccountPopover == kind {
                    presentedAccountPopover = nil
                }
            }
        )
    }

    // 클릭과 hover 진입은 해당 계정 목록 하나만 열어 두 팝업의 동시 표시를 막는다.
    private func presentAccountPopover(_ kind: AccountPopoverKind) {
        guard !store.isBusy, accountPopoverIsAvailable(kind) else { return }
        accountPopoverCloseTask?.cancel()
        accountPopoverSuppressesHover = false
        presentedAccountPopover = kind
    }

    private func setAccountPopoverRowHovered(
        _ kind: AccountPopoverKind,
        hovering: Bool
    ) {
        if hovering {
            accountPopoverCloseTask?.cancel()
            accountPopoverSuppressesHover = false
            hoveredAccountPopoverRow = kind
            presentedAccountPopover = kind
        } else if hoveredAccountPopoverRow == kind {
            hoveredAccountPopoverRow = nil
        }
        reconcileAccountPopoverHover()
    }

    private func setAccountPopoverHovered(
        _ kind: AccountPopoverKind,
        hovering: Bool
    ) {
        if hovering {
            accountPopoverCloseTask?.cancel()
            hoveredAccountPopover = kind
        } else if hoveredAccountPopover == kind {
            hoveredAccountPopover = nil
        }
        reconcileAccountPopoverHover()
    }

    private func clearHoveredAccountPopover(_ kind: AccountPopoverKind) {
        if hoveredAccountPopover == kind {
            hoveredAccountPopover = nil
        }
        reconcileAccountPopoverHover()
    }

    // 행에서 팝업으로 이동하는 짧은 간격 동안에는 기존 280ms 닫힘 지연을 유지한다.
    private func reconcileAccountPopoverHover() {
        accountPopoverCloseTask?.cancel()

        guard let presentedAccountPopover,
              !store.isBusy,
              accountPopoverIsAvailable(presentedAccountPopover),
              !accountPopoverSuppressesHover else {
            self.presentedAccountPopover = nil
            return
        }

        if hoveredAccountPopoverRow == presentedAccountPopover
            || hoveredAccountPopover == presentedAccountPopover {
            return
        }

        let closingKind = presentedAccountPopover
        accountPopoverCloseTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled,
                  self.presentedAccountPopover == closingKind,
                  hoveredAccountPopoverRow != closingKind,
                  hoveredAccountPopover != closingKind else { return }
            self.presentedAccountPopover = nil
        }
    }

    private func accountPopoverIsAvailable(_ kind: AccountPopoverKind) -> Bool {
        switch kind {
        case .switchAccount:
            return hasAccountSwitchTarget
        case .removeAccount:
            return !store.accounts.isEmpty
        }
    }

    // 변경 대상 선택은 팝업을 먼저 닫은 뒤 기존 안전한 전환 흐름으로 바로 넘긴다.
    private func selectAccountForSwitch(_ item: AccountListItem) {
        guard item.account.accountKey != store.activeAccountKey else { return }
        closeAccountPopoverAfterSelection()
        store.switchAccount(to: item)
    }

    // 팝업을 먼저 닫은 뒤 독립적인 app-modal 확인창을 열어 메뉴바 창 닫힘과 액션 유실을 막는다.
    private func selectAccountForRemoval(_ item: AccountListItem) {
        closeAccountPopoverAfterSelection()

        Task { @MainActor in
            await Task.yield()
            guard !store.isBusy else { return }
            guard SystemConfirmationAlert.present(
                title: "이 계정을 이 Mac에서 제거할까요?",
                message: removalMessage(for: item),
                confirmTitle: "제거",
                confirmIsDestructive: true
            ) else { return }
            store.removeAccount(item)
        }
    }

    private func closeAccountPopoverAfterSelection() {
        accountPopoverCloseTask?.cancel()
        accountPopoverSuppressesHover = true
        presentedAccountPopover = nil
        hoveredAccountPopover = nil
    }

    private func dismissAccountPopover() {
        accountPopoverCloseTask?.cancel()
        presentedAccountPopover = nil
        hoveredAccountPopover = nil
        hoveredAccountPopoverRow = nil
        accountPopoverSuppressesHover = false
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

    private func noticeTextColor(for style: AccountStore.NoticeStyle) -> Color {
        switch style {
        case .success: CodexSwitchDesign.successText(for: colorScheme)
        case .warning: CodexSwitchDesign.warningText(for: colorScheme)
        case .error: CodexSwitchDesign.errorText(for: colorScheme)
        }
    }
}

// 명령마다 다른 SF Symbol 폭을 고정해 아이콘과 텍스트 열을 맞춘다.
private struct MenuCommandLabel: View {
    let title: String
    let systemImage: String
    var trailingText: String?
    var trailingSystemImage: String?

    init(
        title: String,
        systemImage: String,
        trailingText: String? = nil,
        trailingSystemImage: String? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.trailingText = trailingText
        self.trailingSystemImage = trailingSystemImage
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .frame(width: 16, alignment: .center)

            Text(title)

            Spacer(minLength: 8)

            if let trailingSystemImage {
                Image(systemName: trailingSystemImage)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary)
            }

            if let trailingText {
                Text(trailingText)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(Color.primary)
    }
}

// 메뉴 명령은 전체 행을 클릭·hover 영역으로 사용한다.
private struct MenuCommandRow<LabelContent: View>: View {
    let isDisabled: Bool
    let action: () -> Void
    let label: () -> LabelContent

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    init(
        isDisabled: Bool,
        action: @escaping () -> Void,
        @ViewBuilder label: @escaping () -> LabelContent
    ) {
        self.isDisabled = isDisabled
        self.action = action
        self.label = label
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                label()
                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
            .padding(.horizontal, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            MenuCommandButtonStyle(
                isHovered: isHovered && !isDisabled,
                colorScheme: colorScheme
            )
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .disabled(isDisabled)
    }
}

private struct MenuCommandButtonStyle: ButtonStyle {
    let isHovered: Bool
    let colorScheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                configuration.isPressed
                    ? CodexSwitchDesign.pressedBackground(for: colorScheme)
                    : isHovered
                        ? CodexSwitchDesign.hoverBackground(for: colorScheme)
                        : Color.clear,
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
    }
}

// 명령 결과를 짧고 닫을 수 있는 상태 배너로 표시한다.
private struct NoticeBanner: View {
    let notice: AccountStore.Notice
    let dismiss: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isExpanded = false
    @State private var disclosureIsHovered = false
    @State private var collapsedTextHeight: CGFloat = 0
    @State private var naturalTextHeight: CGFloat = 0

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: iconName)
                .foregroundStyle(textTint)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                messageText

                if showsDisclosure {
                    disclosureButton
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("메시지 닫기")
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(tint.opacity(0.22), lineWidth: 1)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .accessibilityElement(children: .contain)
    }

    // 실제 텍스트 폭에서 한 줄 높이와 자연 높이를 비교해 disclosure 필요 여부를 판정한다.
    private var messageText: some View {
        Text(notice.message)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(isExpanded ? nil : 1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { collapsedHeightMeasurement }
            .background { naturalHeightMeasurement }
            .onPreferenceChange(CollapsedNoticeHeightKey.self) { height in
                if abs(collapsedTextHeight - height) > 0.25 {
                    collapsedTextHeight = height
                }
            }
            .onPreferenceChange(NaturalNoticeHeightKey.self) { height in
                if abs(naturalTextHeight - height) > 0.25 {
                    naturalTextHeight = height
                }
            }
    }

    // 측정 복제본은 background 안에서만 존재해 메뉴의 실제 높이를 밀어내지 않는다.
    private var collapsedHeightMeasurement: some View {
        Text(notice.message)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: CollapsedNoticeHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var naturalHeightMeasurement: some View {
        Text(notice.message)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(nil)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: NaturalNoticeHeightKey.self,
                        value: proxy.size.height
                    )
                }
            }
            .hidden()
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    // 긴 안내만 텍스트 컬럼 중앙의 chevron으로 펼치고 접는다.
    private var disclosureButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 9, weight: .semibold))
                .frame(width: 22, height: 18)
                .background(
                    disclosureIsHovered ? tint.opacity(0.13) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 5, style: .continuous)
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(textTint)
        .onHover { hovering in
            disclosureIsHovered = hovering
        }
        .accessibilityIdentifier("notice-disclosure")
        .help(isExpanded ? "안내 접기" : "전체 안내 펼치기")
        .accessibilityLabel(isExpanded ? "안내 접기" : "전체 안내 펼치기")
    }

    // 실제 한 줄 높이를 넘는 안내에만 disclosure를 노출한다.
    private var showsDisclosure: Bool {
        collapsedTextHeight > 0
            && naturalTextHeight > collapsedTextHeight + 0.5
    }

    private var tint: Color {
        switch notice.style {
        case .success: CodexSwitchDesign.aqua
        case .warning: CodexSwitchDesign.amber
        case .error: CodexSwitchDesign.coral
        }
    }

    // 배너 아이콘은 상태 의미를 유지하면서 밝은 테마의 대비를 높인다.
    private var textTint: Color {
        switch notice.style {
        case .success: CodexSwitchDesign.successText(for: colorScheme)
        case .warning: CodexSwitchDesign.warningText(for: colorScheme)
        case .error: CodexSwitchDesign.errorText(for: colorScheme)
        }
    }

    private var iconName: String {
        switch notice.style {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

// 안내문 측정값은 같은 텍스트 컬럼에서 한 줄과 자연 높이를 독립적으로 전달한다.
private struct CollapsedNoticeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct NaturalNoticeHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
