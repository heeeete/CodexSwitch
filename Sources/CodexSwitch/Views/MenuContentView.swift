import SwiftUI

// 기본 메뉴 위쪽의 계정 요약과 설정 토글을 구성한다.
struct MenuContentView: View {
    @ObservedObject var store: AccountStore
    @ObservedObject var updateStore: UpdateStore = UpdateStore()
    @Environment(\.colorScheme) private var colorScheme
    @State private var refreshIsHovered = false
    @State private var autoRefreshRowIsHovered = false
    @State private var restartRowIsHovered = false
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
        // 메뉴 창의 기본 재질을 그대로 사용하고 별도 배경을 겹치지 않는다.
        .task {
            await store.loadLocalAccounts()
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
                    : "사용량과 쿠폰 새로 고침"
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
                    isDisabled: store.isBusy,
                    resetCreditState: store.resetCreditState
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
                        .font(.system(size: 13))

                    Text("1분마다")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)

                    Spacer()

                    Toggle("자동 새로고침", isOn: $store.autoRefreshEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .frame(minHeight: 28)
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
                .help("메뉴를 닫아도 1분마다 사용량과 쿠폰을 새로 고칩니다.")

                HStack(spacing: 8) {
                    Text("변경 후 ChatGPT 열기")
                        .font(.system(size: 13))

                    Spacer()

                    Toggle("", isOn: $store.restartChatGPTAfterSwitch)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                }
                .frame(minHeight: 28)
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
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 6)

            // 준비된 업데이트는 버전 번호 없이 하단에서 재시작을 안내한다.
            if updateStore.status != .idle {
                sectionDivider
                    .padding(.horizontal, 12)
                UpdateNoticeView(updateStore: updateStore, isBusy: store.isBusy)
            }
        }
    }

    private var headerSubtitle: String {
        guard !store.accounts.isEmpty else { return "연결된 계정 없음" }
        return "계정 \(store.accounts.count)개"
    }

    private var sectionDivider: some View {
        Divider()
    }

    private func noticeTextColor(for style: AccountStore.NoticeStyle) -> Color {
        switch style {
        case .success: CodexSwitchDesign.successText(for: colorScheme)
        case .warning: CodexSwitchDesign.warningText(for: colorScheme)
        case .error: CodexSwitchDesign.errorText(for: colorScheme)
        }
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
