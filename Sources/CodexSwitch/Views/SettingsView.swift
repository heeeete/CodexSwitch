import SwiftUI

// 업데이트 설정은 시스템 기본 폼과 컨트롤로 제공한다.
struct SettingsView: View {
    @ObservedObject var updateStore: UpdateStore
    @ObservedObject var accountStore: AccountStore

    var body: some View {
        Form {
            Section {
                LabeledContent("현재 버전") {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .foregroundStyle(.secondary)
                }

                Toggle("자동 업데이트 확인", isOn: Binding(
                    get: { updateStore.automaticallyChecksForUpdates },
                    set: { updateStore.setAutomaticallyChecksForUpdates($0) }
                ))
                .disabled(accountStore.isRestartingForUpdate)

                HStack {
                    Text(updateStore.checkMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("지금 확인") { updateStore.checkForUpdates() }
                        .disabled(!updateStore.canCheckForUpdates || accountStore.isRestartingForUpdate
                            || (updateStore.status != .idle && updateStore.status != .failed))
                }
            } header: {
                Text("앱 업데이트")
            } footer: {
                Text("자동 확인을 켜면 1시간마다 새 버전을 확인하고 미리 준비합니다. 설치할 때는 다시 시작할지 물어볼게요.")
            }

            // 설정 창에서도 메뉴 하단과 같은 재시작 동작을 사용할 수 있다.
            if updateStore.status != .idle {
                Section {
                    UpdateNoticeView(updateStore: updateStore, isBusy: accountStore.isBusy)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle("CodexSwitch 설정")
    }
}
