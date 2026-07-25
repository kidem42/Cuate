import AppKit

/// Deterministic, dictionary-based word validation — no LLM.
///
/// Uses the system spell checker (`NSSpellChecker`), which ships with macOS and
/// carries dictionaries for every language the user has installed. This is what
/// makes the auto-switch decision deterministic *and* multilingual: "is this
/// word a real word in language X?" is answered by the OS, not a model.
final class LanguageValidator {
    private let checker = NSSpellChecker.shared

    /// Spell-checker languages actually available on this Mac (e.g. `en`, `ru`,
    /// `es`, `en_GB`). Cached — the set only changes when the user installs a
    /// dictionary.
    private lazy var available: [String] = checker.availableLanguages

    /// Picks the installed spell-checker language that best matches an input
    /// source's language codes (exact id first, then a 2-letter prefix match).
    /// Returns nil when no dictionary is installed for that language, in which
    /// case the caller conservatively skips that candidate.
    func bestLanguage(for codes: [String]) -> String? {
        for code in codes {
            if let exact = available.first(where: { $0.caseInsensitiveCompare(code) == .orderedSame }) {
                return exact
            }
            let prefix = String(code.prefix(2)).lowercased()
            if let byPrefix = available.first(where: { $0.lowercased().hasPrefix(prefix) }) {
                return byPrefix
            }
        }
        return nil
    }

    /// Forces each language's dictionary to load ahead of time (S3), so the
    /// first real word doesn't pay a cold-start spike on the hot path.
    func warm(languages: [String]) {
        for language in languages {
            _ = isValidWord("warmup", language: language)
        }
    }

    /// True when `word` is spelled correctly in `language` — i.e. the spell
    /// checker finds no misspelling in it.
    func isValidWord(_ word: String, language: String) -> Bool {
        let range = checker.checkSpelling(
            of: word,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: 0,
            wordCount: nil
        )
        return range.location == NSNotFound
    }
}
