import Foundation

/// Cheap, corpus-free "does this look like a real word" heuristic.
///
/// Works per *script*, not per language: one vowel set for Latin (covers
/// English, Spanish, German, French, …) and one for Cyrillic (Russian, …). So
/// all Latin languages share a single check and Cyrillic another — no
/// per-language tables. It's a confidence signal, not a hard rule: wrong-layout
/// gibberish tends to have no vowels or absurd consonant runs (e.g. "ghbdtn").
enum PlausibilityScorer {

    /// Latin vowels incl. common accented forms (Spanish/French/German/…).
    private static let latinVowels = Set("aeiouyàáâäãåèéêëìíîïòóôöõøùúûüýÿœæ")
    /// Cyrillic vowels (й treated as a vowel-ish glide so it doesn't inflate runs).
    private static let cyrillicVowels = Set("аеёиоуыэюяй")

    /// A word is "plausible" when it contains a vowel and has no run of more
    /// than `maxConsonantRun` consecutive consonants.
    static func isPlausible(_ word: String, maxConsonantRun: Int = 4) -> Bool {
        let lower = word.lowercased()
        guard let first = lower.unicodeScalars.first else { return false }
        let vowels = isCyrillic(first) ? cyrillicVowels : latinVowels

        var hasVowel = false
        var run = 0
        for ch in lower {
            if vowels.contains(ch) {
                hasVowel = true
                run = 0
            } else if ch.isLetter {
                run += 1
                if run > maxConsonantRun { return false }
            } else {
                run = 0   // punctuation/digits don't count toward a run
            }
        }
        return hasVowel
    }

    private static func isCyrillic(_ scalar: Unicode.Scalar) -> Bool {
        (0x0400...0x04FF).contains(scalar.value)
    }
}
