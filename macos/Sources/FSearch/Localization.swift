import Combine
import Foundation

enum AppLanguage: String, CaseIterable, Identifiable {
    case system, simplifiedChinese = "zh-Hans", english = "en"
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return L("自动（跟随系统）")
        case .simplifiedChinese: return L("简体中文")
        case .english: return "English"
        }
    }
}

enum Localization {
    static let preferenceKey = "FSearch.language"
    static var languageCode: String {
        let choice = AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "") ?? .system
        if choice != .system { return choice.rawValue }
        let system = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleLanguages"] as? [String]
        return (system ?? Locale.preferredLanguages).first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }
    private static let resources = Bundle.main.url(forResource: "FSearch_FSearch", withExtension: "bundle")
        .flatMap(Bundle.init(url:)) ?? Bundle.module
    private static let bundles: [String: Bundle] = Dictionary(uniqueKeysWithValues: ["zh-Hans", "en"].compactMap { code in
        resources.url(forResource: code, withExtension: "lproj").flatMap(Bundle.init(url:)).map { (code, $0) }
    })
    static var bundle: Bundle { bundles[languageCode] ?? resources }
    static func string(_ key: String) -> String { bundle.localizedString(forKey: key, value: key, table: nil) }
}

/// Foundation retains interpolation arguments and resolves them in the selected language.
func L(_ key: String.LocalizationValue) -> String {
    String(localized: key, bundle: Localization.bundle, locale: Locale(identifier: Localization.languageCode))
}

extension String {
    var localized: String { Localization.string(self) }
}

@MainActor
final class LanguageSettings: ObservableObject {
    static let shared = LanguageSettings()
    @Published var selection: AppLanguage {
        didSet {
            UserDefaults.standard.set(selection.rawValue, forKey: Localization.preferenceKey)
            applyNativeLanguage()
        }
    }
    @Published private(set) var systemRevision = 0
    var locale: Locale { Locale(identifier: Localization.languageCode) }
    private var subscription: AnyCancellable?

    private init() {
        selection = AppLanguage(rawValue: UserDefaults.standard.string(forKey: Localization.preferenceKey) ?? "") ?? .system
        applyNativeLanguage()
        subscription = NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)
            .receive(on: RunLoop.main).sink { [weak self] _ in
                guard let self, self.selection == .system else { return }
                self.systemRevision += 1
            }
    }

    private func applyNativeLanguage() {
        if selection == .system { UserDefaults.standard.removeObject(forKey: "AppleLanguages") }
        else { UserDefaults.standard.set([selection.rawValue], forKey: "AppleLanguages") }
    }
}
