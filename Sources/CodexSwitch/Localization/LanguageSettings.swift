import Foundation
import Combine

// 앱 언어만 저장하며 계정·조회·업데이트 설정은 변경하지 않는다.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, korean = "ko", english = "en"
    var id: String { rawValue }

    func resolved(preferredLanguages: [String] = Locale.preferredLanguages) -> String {
        guard self == .system else { return rawValue }
        let first = preferredLanguages.first?.lowercased().replacingOccurrences(of: "_", with: "-") ?? "en"
        return first == "ko" || first.hasPrefix("ko-") ? "ko" : "en"
    }
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    @Published var selection: AppLanguage {
        didSet { defaults.set(selection.rawValue, forKey: L10n.preferenceKey) }
    }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        selection = AppLanguage(rawValue: defaults.string(forKey: L10n.preferenceKey) ?? "") ?? .system
    }

    var locale: Locale { Locale(identifier: selection.resolved()) }
}

// Foundation 모델과 오류에서도 같은 번역을 사용하며 표시 문구만 바꾼다.
enum L10n {
    static let preferenceKey = "appLanguage"
    static var language: String {
        (AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system).resolved()
    }

    static let resources: Bundle = {
        #if SWIFT_PACKAGE
        if let url = Bundle.main.url(forResource: "CodexSwitch_CodexSwitch", withExtension: "bundle"),
           let bundle = Bundle(url: url) { return bundle }
        return Bundle.module
        #else
        return Bundle.main
        #endif
    }()

    static func text(_ key: String, _ arguments: String...) -> String {
        let code = language
        let bundle = resources.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? resources
        let format = bundle.localizedString(forKey: key, value: key, table: nil)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale(identifier: code), arguments: arguments)
    }
}
