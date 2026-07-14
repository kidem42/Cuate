import Foundation

/// Deterministic statistical language scorer — the heart of the detection. For each supported language it holds:
///  - a character-trigram table (q = -log10(p)*10, 255 = never occurs), built
///    from the OpenSubtitles frequency corpus, and
///  - a word→frequency map (q scale, lower = more frequent) for the top words.
///
/// Unlike a dictionary, trigram statistics judge ANY string — names, slang,
/// word forms, even typos — "пщщв" is impossible in Russian whether or not the
/// intended word is in a dictionary. Alphabets must match gen_tables.py.
final class NgramScorer {

    struct Score {
        /// Average trigram q over "^word$" (lower = more probable).
        let avgQ: Double
        /// Number of trigrams that never occur in this language.
        let impossible: Int
    }

    let language: String            // "ru" / "en" / "es"
    private let alphabet: [Character: Int]
    private let dim: Int            // alphabet count + 1 (boundary index = count)
    private let table: [UInt8]
    private var wordFreq: [String: UInt8] = [:]

    private static let alphabets: [String: String] = [
        "ru": "абвгдеёжзийклмнопрстуфхцчшщъыьэюя",
        "en": "abcdefghijklmnopqrstuvwxyz",
        "es": "abcdefghijklmnopqrstuvwxyzáéíóúüñ",
    ]

    private init?(language: String, trigramData: Data, wordsText: String) {
        guard let alpha = Self.alphabets[language] else { return nil }
        let chars = Array(alpha)
        self.language = language
        self.dim = chars.count + 1
        guard trigramData.count == dim * dim * dim else { return nil }
        self.alphabet = Dictionary(uniqueKeysWithValues: chars.enumerated().map { ($1, $0) })
        self.table = [UInt8](trigramData)

        wordFreq.reserveCapacity(30_000)
        for line in wordsText.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, let q = UInt8(parts[1]) else { continue }
            wordFreq[String(parts[0])] = q
        }
    }

    /// Loads a language from table files (bundle resources or plain paths).
    static func load(language: String, trigramURL: URL, wordsURL: URL) -> NgramScorer? {
        guard let data = try? Data(contentsOf: trigramURL),
              let words = try? String(contentsOf: wordsURL, encoding: .utf8) else { return nil }
        return NgramScorer(language: language, trigramData: data, wordsText: words)
    }

    /// Loads every language with resources present in the app bundle.
    static func loadBundled() -> [String: NgramScorer] {
        var result: [String: NgramScorer] = [:]
        for lang in alphabets.keys {
            guard let tri = Bundle.main.url(forResource: "trigrams_\(lang)", withExtension: "bin"),
                  let words = Bundle.main.url(forResource: "words_\(lang)", withExtension: "txt"),
                  let scorer = load(language: lang, trigramURL: tri, wordsURL: words) else { continue }
            result[lang] = scorer
        }
        return result
    }

    // MARK: - Scoring

    /// Trigram score of a word (lowercased; characters outside the alphabet
    /// count as impossible). Returns nil for words shorter than 2 letters.
    func charScore(_ word: String) -> Score? {
        let lower = word.lowercased()
        guard lower.count >= 2 else { return nil }
        let boundary = dim - 1
        var seq: [Int] = [boundary]
        var outOfAlphabet = 0
        for ch in lower {
            if let i = alphabet[ch] { seq.append(i) } else { seq.append(boundary); outOfAlphabet += 1 }
        }
        seq.append(boundary)

        var sum = 0.0
        var impossible = outOfAlphabet
        var count = 0
        for i in 0..<(seq.count - 2) {
            let q = table[(seq[i] * dim + seq[i + 1]) * dim + seq[i + 2]]
            if q == 255 { impossible += 1 }
            sum += Double(q)
            count += 1
        }
        return Score(avgQ: sum / Double(count), impossible: impossible)
    }

    /// Word frequency q (lower = more frequent), nil when not in the top list.
    func freqQ(_ word: String) -> Double? {
        wordFreq[word.lowercased()].map(Double.init)
    }
}
