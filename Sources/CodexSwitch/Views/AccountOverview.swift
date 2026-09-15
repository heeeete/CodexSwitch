import SwiftUI

// 실제 활성 계정 하나만 전체 폭 카드와 사용량 상세로 보여준다.
struct AccountOverview: View {
    let accounts: [AccountListItem]
    let activeAccountKey: String?
    let switchingAccountKey: String?
    let removingAccountKey: String?
    let isDisabled: Bool
    var resetCreditState: ResetCreditState = .loading

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
                .padding(.top, 12)
                .padding(.bottom, 14)

                Divider().padding(.horizontal, 16)

                ResetCreditSection(state: resetCreditState)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
            }
        }
    }

    // nil 또는 오래된 active key는 첫 계정을 현재 계정처럼 잘못 표시하지 않는다.
    private var currentAccount: AccountListItem? {
        guard let activeAccountKey else { return nil }
        return accounts.first { $0.account.accountKey == activeAccountKey }
    }
}

// 만료가 가까운 쿠폰부터 남은 시간을 큰 숫자로 표시한다.
struct ResetCreditSection: View {
    let state: ResetCreditState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("초기화 쿠폰").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    if case let .loaded(credits) = state {
                        Text("\(ResetCredit.available(in: credits, at: context.date).count)장")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                }
                switch state {
                case .loading:
                    statusText("쿠폰 조회 중…")
                        // 첫 조회 중 메뉴를 열어도 일반적인 세 장이 도착할 공간을 확보한다.
                        .frame(height: 84, alignment: .topLeading)
                case .failed:
                    statusText("쿠폰을 조회하지 못했어요. 새로고침해 주세요.")
                        .frame(height: 84, alignment: .topLeading)
                case let .loaded(credits):
                    let available = ResetCredit.available(in: credits, at: context.date)
                    if available.isEmpty {
                        statusText("사용 가능한 쿠폰 없음")
                    } else {
                        // 긴 목록은 스크롤하고 일반적인 세 장은 한눈에 표시한다.
                        ScrollView {
                            VStack(spacing: 0) {
                                ForEach(Array(available.enumerated()), id: \.element.id) { index, credit in
                                    HStack(spacing: 10) {
                                        Image(systemName: "ticket").font(.system(size: 14))
                                            .accessibilityHidden(true)
                                        Text("쿠폰 \(index + 1)").font(.system(size: 13))
                                        Spacer(minLength: 4)
                                        Text("남은 시간").font(.system(size: 10))
                                            .foregroundStyle(.secondary)
                                        Text(credit.remainingTime(at: context.date))
                                            .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                            .frame(minWidth: 76, alignment: .trailing)
                                    }
                                    .frame(height: 28)
                                    .accessibilityElement(children: .combine)
                                }
                            }
                        }
                        .frame(height: CGFloat(min(available.count, 3)) * 28)
                    }
                }
            }
            .foregroundStyle(CodexSwitchDesign.smallText(for: colorScheme))
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(.secondary)
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
        } else if let refreshedAt = item.refreshedAt {
            TimelineView(
                .periodic(
                    from: refreshedAt,
                    by: 60
                )
            ) { context in
                Text(AccountRefreshStatus.text(
                    since: refreshedAt,
                    now: context.date
                ))
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(CodexSwitchDesign.warningText(for: colorScheme))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            }
        }
    }
}

// 일반 Codex 기록에 실제로 있는 창만 표시하므로 5시간 창의 추가·제거도 반영한다.
private struct ActiveAccountDetail: View {
    let item: AccountListItem

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let meters = [item.account.lastUsage?.primary, item.account.lastUsage?.secondary]
                .compactMap { $0 }.compactMap { UsageMeter(window: $0, now: context.date) }
                .sorted { $0.windowMinutes < $1.windowMinutes }
            VStack(spacing: 14) {
                if meters.isEmpty {
                    Text("사용량 정보 없음")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 50, alignment: .leading)
                } else {
                    ForEach(meters) { meter in
                        DetailedUsageMeterRow(meter: meter, date: context.date, isCompact: meters.count > 1)
                    }
                }
            }
            .accessibilityElement(children: .contain)
        }
    }
}

// 잔여 비율을 가장 크게, 초기화까지 남은 시간과 소비 비율을 보조 정보로 보여준다.
private struct DetailedUsageMeterRow: View {
    let meter: UsageMeter
    let date: Date
    let isCompact: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meter.displayTitle).font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("\(meter.remainingPercent)%")
                            .font(.system(size: isCompact ? 32 : 40, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("남음").font(.system(size: 16, weight: .medium)).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                Rectangle().fill(CodexSwitchDesign.hairline(for: colorScheme))
                    .frame(width: 1, height: 38)
                VStack(alignment: .leading, spacing: 4) {
                    Text("초기화까지").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(meter.resetCountdown(at: date) ?? "—")
                        .font(.system(size: 16, weight: .semibold, design: .monospaced))
                }
                .padding(.leading, 6)
                .padding(.bottom, 4)
            }
            // 넓은 막대는 남은 비율을 그대로 채워 숫자와 시각 정보가 일치하게 한다.
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.18))
                    Capsule().fill(barColor)
                        .frame(width: proxy.size.width * CGFloat(meter.remainingPercent) / 100)
                }
            }
            .frame(height: 10)
            .accessibilityHidden(true)
            Text("\(100 - meter.remainingPercent)% 사용")
                .font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var barColor: Color {
        if meter.remainingPercent <= 10 { return CodexSwitchDesign.coral }
        if meter.remainingPercent <= 25 { return CodexSwitchDesign.amber }
        return CodexSwitchDesign.aqua
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

// 마지막 새로고침 성공 시각을 기존 메뉴 문구 그대로 상대 시간으로 바꾼다.
enum AccountRefreshStatus {
    static func text(since refreshedAt: Date, now: Date = Date()) -> String {
        let age = max(0, now.timeIntervalSince(refreshedAt))

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
