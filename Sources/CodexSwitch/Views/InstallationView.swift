import SwiftUI

// 앱에서 Applications로 이어지는 하나의 흐름을 보여 주고 복구가 필요할 때만 버튼을 제공한다.
struct InstallationView: View {
    @ObservedObject var startup: AppStartup

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 24) {
                CodexSwitchIconView(size: 64)
                Image(systemName: "arrow.right")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(.tertiary)
                Image(systemName: "folder.fill")
                    .font(.system(size: 62, weight: .regular))
                    .foregroundStyle(CodexSwitchDesign.aqua.gradient)
                    .overlay {
                        Image(systemName: "a.square.fill")
                            .font(.system(size: 22, weight: .medium))
                            .foregroundStyle(.white.opacity(0.9))
                            .offset(y: 5)
                    }
            }
            .accessibilityHidden(true)
            .padding(.bottom, 24)

            Text(startup.installationError == nil ? "CodexSwitch를 설치하고 있어요" : "설치를 마치려면 확인이 필요해요")
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .padding(.bottom, 10)

            Text(startup.installationError ?? "응용 프로그램 폴더에 넣은 뒤 자동으로 열립니다.\n다음 업데이트부터는 앱 안에서 편하게 설치하세요.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
                .padding(.bottom, 24)

            if startup.installationError == nil {
                ProgressView().controlSize(.small)
                    .accessibilityLabel("앱 설치 중")
            } else {
                HStack(spacing: 12) {
                    Button("종료") { NSApp.terminate(nil) }
                        .keyboardShortcut(.cancelAction)
                    Button("다시 시도") { startup.installOrStart() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 40)
        .frame(width: 460)
        .frame(minHeight: 330)
        .background(.regularMaterial)
    }
}
