import Foundation

/// Expected copy is independent of the production catalog. The same behavioral
/// tests run with -testLanguage en and -testLanguage zh-Hans.
func expectedLocalized(_ english: String, _ simplifiedChinese: String) -> String {
    Bundle.main.preferredLocalizations.first?.hasPrefix("zh") == true
        ? simplifiedChinese : english
}
