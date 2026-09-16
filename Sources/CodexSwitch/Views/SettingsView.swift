import SwiftUI

// 업데이트 설정은 시스템 기본 폼과 컨트롤로 제공한다.
struct SettingsView: View {
    @ObservedObject var updateStore: UpdateStore
    @ObservedObject var accountStore: AccountStore
    @ObservedObject private var language = LanguageSettings.shared

    var body: some View {
        Form {
            // 시스템 기본 언어 또는 사용자가 고른 앱 언어만 변경한다.
            Section {
                Picker(L10n.text("언어"), selection: $language.selection) {
                    Text(L10n.text("시스템 설정 따르기")).tag(AppLanguage.system)
                    Text("한국어").tag(AppLanguage.korean)
                    Text("English").tag(AppLanguage.english)
                }
            } footer: {
                Text(L10n.text("언어 변경은 즉시 적용되며 다음 실행에도 유지됩니다."))
            }
            Section {
                LabeledContent(L10n.text("현재 버전")) {
                    Text(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—")
                        .foregroundStyle(.secondary)
                }

                Toggle(L10n.text("자동 업데이트 확인"), isOn: Binding(
                    get: { updateStore.automaticallyChecksForUpdates },
                    set: { updateStore.setAutomaticallyChecksForUpdates($0) }
                ))
                .disabled(accountStore.isRestartingForUpdate)

                HStack {
                    Text(updateStore.checkMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button(L10n.text("지금 확인")) { updateStore.checkForUpdates() }
                        .disabled(!updateStore.canCheckForUpdates || accountStore.isRestartingForUpdate
                            || (updateStore.status != .idle && updateStore.status != .failed))
                }
            } header: {
                Text(L10n.text("앱 업데이트"))
            } footer: {
                Text(L10n.text("자동 확인을 켜면 1시간마다 새 버전을 확인하고 미리 준비합니다. 설치할 때는 다시 시작할지 물어볼게요."))
            }

            // 설정 창에서도 메뉴 하단과 같은 재시작 동작을 사용할 수 있다.
            if updateStore.status != .idle {
                Section {
                    UpdateNoticeView(updateStore: updateStore, isBusy: accountStore.isBusy)
                }
            }
        }
        .id(language.selection)
        .environment(\.locale, language.locale)
        .formStyle(.grouped)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .navigationTitle(L10n.text("CodexSwitch 설정"))
    }
}
