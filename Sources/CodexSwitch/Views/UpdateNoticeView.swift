import SwiftUI

// 업데이트가 있을 때만 보이는 간단한 안내와 재시작 버튼이다.
struct UpdateNoticeView: View {
    @ObservedObject var updateStore: UpdateStore
    let isBusy: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(updateStore.message)
                .font(.system(size: 11, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)

            if let actionTitle = updateStore.actionTitle {
                HStack {
                    Spacer()
                    Button(actionTitle) { updateStore.performAction() }
                        .controlSize(.small)
                        .disabled(isBusy)
                        .help(isBusy ? "진행 중인 계정 작업이 끝나면 업데이트할 수 있어요." : actionTitle)
                }
            } else {
                ProgressView()
                    .controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
    }
}
