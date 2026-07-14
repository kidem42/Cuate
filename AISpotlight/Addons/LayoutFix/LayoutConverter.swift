import Foundation

/// Positional keyboard-layout converter.
///
/// Maps text between the US-QWERTY and Russian-ЙЦУКЕН layouts by *physical key
/// position* — the key that types `q` on QWERTY types `й` on ЙЦУКЕН, so
/// "ghbdtn" flips to "привет" and back. Pure, deterministic, offline; no
/// dependency on the rest of the app, which keeps the whole addon self-contained
/// and this file trivially unit-testable.
enum LayoutConverter {

    /// EN → RU by key position (unshifted + shifted). RU → EN is the inverse.
    /// Digits are identical in both layouts, so they're intentionally absent
    /// (left unchanged). Only letters + the punctuation that actually differs
    /// between the two layouts are listed.
    private static let enToRuPairs: [(Character, Character)] = [
        // Unshifted
        ("`", "ё"), ("q", "й"), ("w", "ц"), ("e", "у"), ("r", "к"), ("t", "е"),
        ("y", "н"), ("u", "г"), ("i", "ш"), ("o", "щ"), ("p", "з"), ("[", "х"),
        ("]", "ъ"), ("a", "ф"), ("s", "ы"), ("d", "в"), ("f", "а"), ("g", "п"),
        ("h", "р"), ("j", "о"), ("k", "л"), ("l", "д"), (";", "ж"), ("'", "э"),
        ("z", "я"), ("x", "ч"), ("c", "с"), ("v", "м"), ("b", "и"), ("n", "т"),
        ("m", "ь"), (",", "б"), (".", "ю"), ("/", "."),
        // Shifted
        ("~", "Ё"), ("Q", "Й"), ("W", "Ц"), ("E", "У"), ("R", "К"), ("T", "Е"),
        ("Y", "Н"), ("U", "Г"), ("I", "Ш"), ("O", "Щ"), ("P", "З"), ("{", "Х"),
        ("}", "Ъ"), ("A", "Ф"), ("S", "Ы"), ("D", "В"), ("F", "А"), ("G", "П"),
        ("H", "Р"), ("J", "О"), ("K", "Л"), ("L", "Д"), (":", "Ж"), ("\"", "Э"),
        ("Z", "Я"), ("X", "Ч"), ("C", "С"), ("V", "М"), ("B", "И"), ("N", "Т"),
        ("M", "Ь"), ("<", "Б"), (">", "Ю"), ("?", ",")
    ]

    private static let enToRu: [Character: Character] = {
        Dictionary(uniqueKeysWithValues: enToRuPairs.map { ($0.0, $0.1) })
    }()

    private static let ruToEn: [Character: Character] = {
        Dictionary(uniqueKeysWithValues: enToRuPairs.map { ($0.1, $0.0) })
    }()

    /// Which way a piece of text should be flipped.
    enum Direction { case enToRu, ruToEn }

    /// Guesses the intended direction from the dominant alphabet: Cyrillic
    /// letters mean the user meant Latin (and vice-versa). Punctuation/digits
    /// don't vote, so a fully-punctuation string stays put.
    static func detectDirection(_ text: String) -> Direction? {
        var cyrillic = 0
        var latin = 0
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x0400...0x04FF: cyrillic += 1                       // Cyrillic block
            case 0x41...0x5A, 0x61...0x7A: latin += 1                 // A–Z, a–z
            default: break
            }
        }
        if cyrillic == 0 && latin == 0 { return nil }
        return cyrillic > latin ? .ruToEn : .enToRu
    }

    /// Converts every character through the given map, leaving anything not in
    /// the map (digits, spaces, emoji, already-correct punctuation) untouched.
    static func convert(_ text: String, direction: Direction) -> String {
        let map = direction == .enToRu ? enToRu : ruToEn
        return String(text.map { map[$0] ?? $0 })
    }

    /// The offline "fix layout" action: auto-detects the direction and flips.
    /// Returns the input unchanged when there's nothing alphabetic to flip.
    static func flip(_ text: String) -> String {
        guard let direction = detectDirection(text) else { return text }
        return convert(text, direction: direction)
    }
}
