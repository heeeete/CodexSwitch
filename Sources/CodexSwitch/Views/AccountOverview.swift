import SwiftUI

// 실제 활성 계정 하나만 전체 폭 카드와 사용량 상세로 보여준다.
struct AccountOverview: View {
    let accounts: [AccountListItem]
    let activeAccountKey: String?
    let switchingAccountKey: String?
    let removingAccountKey: String?
    let isDisabled: Bool

    var body: some View {
        if let currentAccount {
            VStack(spacing: 0) {
                CurrentAccountCard(
                    item: currentAccount,
                    isBusy: switchingAccountKey != nil
                        || currentAccount.account.accountKey == removingAccountKey,
                    isDisabled: isDisabled
                )
                .padding(.horizontal, 12)
                .padding(.top, 7)
                .padding(.bottom, 6)

                ActiveAccountDetail(item: currentAccount)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
            }
        }
    }

    // nil 또는 오래된 active key는 첫 계정을 현재 계정처럼 잘못 표시하지 않는다.
    private var currentAccount: AccountListItem? {
        guard let activeAccountKey else { return nil }
        return accounts.first { $0.account.accountKey == activeAccountKey }
    }
}

// 현재 계정 카드는 기존 선택 스타일을 유지하면서 가로 공간을 모두 사용한다.
private struct CurrentAccountCard: View {
    let item: AccountListItem
    let isBusy: Bool
    let isDisabled: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        AccountSwitcherTab(
            item: item,
            isSelected: true,
            isBusy: isBusy,
            isDisabled: isDisabled,
            action: {}
        )
        .frame(maxWidth: .infinity, minHeight: 34, maxHeight: 34)
        .background(
            CodexSwitchDesign.cardBackground(for: colorScheme),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(CodexSwitchDesign.hairline(for: colorScheme), lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// 계정 선택 탭은 이름과 플랜만 남겨 좁은 폭에서도 한 줄로 훑을 수 있게 한다.
private struct AccountSwitcherTab: View {
    let item: AccountListItem
    let isSelected: Bool
    let isBusy: Bool
    let isDisabled: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(item.account.displayName)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(item.account.displayPlan.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(0.4)
                    .foregroundStyle(
                        isSelected
                            ? CodexSwitchDesign.accentText(for: colorScheme)
                            : CodexSwitchDesign.secondaryText(for: colorScheme)
                    )
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(
                        (isSelected ? CodexSwitchDesign.iris : Color.secondary).opacity(0.1),
                        in: Capsule()
                    )

                Spacer(minLength: 6)

                trailingStatus
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            AccountSwitcherTabStyle(
                isSelected: isSelected,
                isHovered: isHovered && !isDisabled,
                colorScheme: colorScheme
            )
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .disabled(isDisabled || isSelected)
        .help(isSelected ? "현재 계정" : "이 계정으로 전환")
        .accessibilityLabel("\(item.account.displayName), \(item.account.displayPlan), \(isSelected ? "현재 계정" : "전환")")
    }

    // 갱신 상태와 작업 중 표시는 계정 카드의 오른쪽 끝 한 자리에서 교체된다.
    @ViewBuilder
    private var trailingStatus: some View {
        if isBusy {
            ProgressView()
                .controlSize(.mini)
        } else if let lastUsageAt = item.account.lastUsageAt {
            TimelineView(
                .periodic(
                    from: Date(timeIntervalSince1970: TimeInterval(lastUsageAt)),
                    by: 60
                )
            ) { context in
                if let freshnessText = AccountUsageFreshness.text(
                    for: item.account,
                    now: context.date
                ) {
                    Text(freshnessText)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(CodexSwitchDesign.warningText(for: colorScheme))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
    }
}

// 선택된 계정의 사용량 창만 넓은 막대로 자세히 보여준다.
private struct ActiveAccountDetail: View {
    let item: AccountListItem

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 6) {
            if item.account.usageMeters.isEmpty {
                Text("사용량 정보 없음")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(CodexSwitchDesign.smallText(for: colorScheme))
                    .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
            } else {
                ForEach(item.account.usageMeters) { meter in
                    DetailedUsageMeterRow(meter: meter)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}

// 상세 사용량 행은 남은 비율과 정확한 재설정 카운트다운을 한 줄에 맞춘다.
private struct DetailedUsageMeterRow: View {
    let meter: UsageMeter

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if meter.resetsAt != nil {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    content(at: context.date)
                }
            } else {
                content(at: Date())
            }
        }
        .help(resetHelp)
    }

    private func content(at date: Date) -> some View {
        HStack(spacing: 8) {
            Text(meter.label.uppercased())
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(CodexSwitchDesign.smallText(for: colorScheme))
                .frame(width: 28, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.16))
                    Capsule()
                        .fill(barColor)
                        .frame(width: proxy.size.width * CGFloat(meter.remainingPercent) / 100)
                }
            }
            .frame(minWidth: 76, maxWidth: 124)
            .frame(height: 5)

            Text("\(meter.remainingPercent)% 남음")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(CodexSwitchDesign.smallText(for: colorScheme))
                .frame(width: 63, alignment: .leading)

            Spacer(minLength: 0)

            Text(meter.resetCountdown(at: date) ?? "—")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(CodexSwitchDesign.secondaryText(for: colorScheme))
                .frame(minWidth: 48, alignment: .trailing)
                .lineLimit(1)
        }
        .frame(minHeight: 23)
    }

    private var barColor: Color {
        if meter.remainingPercent <= 10 { return CodexSwitchDesign.coral }
        if meter.remainingPercent <= 25 { return CodexSwitchDesign.amber }
        return CodexSwitchDesign.aqua
    }

    private var resetHelp: String {
        guard let resetsAt = meter.resetsAt else { return "재설정 시간 정보 없음" }
        return "재설정: \(resetsAt.formatted(date: .abbreviated, time: .shortened))"
    }
}

// 동일한 계정 목록을 전환과 제거 문맥에 맞는 제목·선택 상태로 재사용한다.
enum AccountPickerAction: Equatable {
    case switchAccount
    case removeAccount

    var title: String {
        switch self {
        case .switchAccount: "변경할 계정"
        case .removeAccount: "제거할 계정"
        }
    }

    var systemImage: String {
        switch self {
        case .switchAccount: "person.2"
        case .removeAccount: "person.badge.minus"
        }
    }

    func optionIsDisabled(isActive: Bool, isGloballyDisabled: Bool) -> Bool {
        isGloballyDisabled || (self == .switchAccount && isActive)
    }

    func optionHelp(for item: AccountListItem, isActive: Bool) -> String {
        switch self {
        case .switchAccount:
            return isActive ? "현재 계정" : "\(item.account.displayName) 계정으로 변경"
        case .removeAccount:
            return "이 Mac에서 제거 확인 열기"
        }
    }
}

struct AccountPickerPopover: View {
    let action: AccountPickerAction
    let accounts: [AccountListItem]
    let activeAccountKey: String?
    let isDisabled: Bool
    let selectAction: (AccountListItem) -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label(action.title, systemImage: action.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 3)

            Rectangle()
                .fill(CodexSwitchDesign.hairline(for: colorScheme))
                .frame(height: 1)
                .padding(.horizontal, 4)

            // 연결 계정이 많아져도 팝업이 화면 밖으로 자라지 않도록 목록 높이를 제한한다.
            ScrollView(.vertical, showsIndicators: accounts.count > 6) {
                LazyVStack(spacing: 0) {
                    ForEach(accounts) { item in
                        let isActive = item.account.accountKey == activeAccountKey
                        AccountPickerOptionRow(
                            item: item,
                            isActive: isActive,
                            isDisabled: action.optionIsDisabled(
                                isActive: isActive,
                                isGloballyDisabled: isDisabled
                            ),
                            helpText: action.optionHelp(for: item, isActive: isActive),
                            action: { selectAction(item) }
                        )
                    }
                }
            }
            .frame(height: min(CGFloat(accounts.count) * 40, 240))
        }
        .padding(6)
        .frame(width: 264)
        .background(.regularMaterial)
    }
}

// 계정 후보 행은 기존 중립 색상과 현재 계정 체크 표시를 그대로 유지한다.
private struct AccountPickerOptionRow: View {
    let item: AccountListItem
    let isActive: Bool
    let isDisabled: Bool
    let helpText: String
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text(accountInitial)
                    .font(.system(size: 11, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.76))
                    .frame(width: 26, height: 26)
                    .background(Color.secondary.opacity(0.14), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(item.account.displayName)
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    if item.account.displayName != item.account.email {
                        Text(item.account.email)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundStyle(CodexSwitchDesign.secondaryText(for: colorScheme))
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(item.account.displayPlan.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .foregroundStyle(CodexSwitchDesign.secondaryText(for: colorScheme))

                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(CodexSwitchDesign.accentText(for: colorScheme))
                        .accessibilityLabel("현재 계정")
                }
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 40, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(
            AccountOptionButtonStyle(
                isHovered: isHovered && !isDisabled,
                colorScheme: colorScheme
            )
        )
        .onHover { hovering in
            isHovered = hovering
        }
        .disabled(isDisabled)
        .help(helpText)
    }

    private var accountInitial: String {
        String(item.account.displayName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased()
    }
}

// 선택 탭의 활성 그라디언트와 데스크톱 hover 상태를 한 스타일에서 관리한다.
private struct AccountSwitcherTabStyle: ButtonStyle {
    let isSelected: Bool
    let isHovered: Bool
    let colorScheme: ColorScheme

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                backgroundStyle(isPressed: configuration.isPressed),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(borderStyle, lineWidth: 1)
            }
            .scaleEffect(configuration.isPressed ? 0.99 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    private func backgroundStyle(isPressed: Bool) -> AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        CodexSwitchDesign.iris.opacity(colorScheme == .dark ? 0.18 : 0.11),
                        CodexSwitchDesign.aqua.opacity(colorScheme == .dark ? 0.08 : 0.045)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        if isPressed {
            return AnyShapeStyle(CodexSwitchDesign.pressedBackground(for: colorScheme))
        }
        if isHovered {
            return AnyShapeStyle(CodexSwitchDesign.hoverBackground(for: colorScheme))
        }
        return AnyShapeStyle(Color.clear)
    }

    private var borderStyle: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [CodexSwitchDesign.iris.opacity(0.56), CodexSwitchDesign.aqua.opacity(0.30)],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
        }
        return AnyShapeStyle(Color.clear)
    }
}

// 요약·팝업 행은 같은 hover 및 눌림 피드백을 공유한다.
private struct AccountOptionButtonStyle: ButtonStyle {
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

// 마지막 사용량 갱신 시각을 메뉴에 맞는 짧은 상대 시간으로 바꾼다.
enum AccountUsageFreshness {
    static func text(for account: CodexAccount, now: Date = Date()) -> String? {
        guard let lastUsageAt = account.lastUsageAt else { return nil }
        let age = max(0, now.timeIntervalSince1970 - TimeInterval(lastUsageAt))

        switch age {
        case ..<60:
            return "방금 갱신"
        case ..<3_600:
            return "갱신 \(Int(age / 60))분 전"
        case ..<86_400:
            return "갱신 \(Int(age / 3_600))시간 전"
        default:
            return "갱신 \(Int(age / 86_400))일 전"
        }
    }
}
