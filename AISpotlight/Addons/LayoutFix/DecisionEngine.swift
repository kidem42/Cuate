import Foundation

/// Pure, deterministic verdict logic for wrong-layout detection — no AppKit,
/// no side effects, fully unit-testable offline. Thresholds live here and were
/// tuned with the offline accuracy harness (see the addon README).
///
/// All q values are -log10(probability)*10: LOWER = more probable/frequent.
enum DecisionEngine {

    /// One "what if this window was typed in layout X" reading.
    struct Hypothesis {
        let id: String              // layout id
        /// Letters-only core of the rendered window (see coreExtract).
        let core: String
        /// Trigram stats of the core in this layout's language (nil = no model).
        let charAvgQ: Double?
        let impossible: Int
        /// Word-frequency q of the core (nil = not in the top-30k list).
        let freqQ: Double?
        /// System dictionary opinion (nil = no dictionary for the language).
        let dictValid: Bool?
    }

    struct Thresholds {
        /// A "clean" core: no impossible trigrams and avgQ below this.
        /// Harness (7876 words/class): negatives 99.99%, typo-negatives 99.21%,
        /// positives 98.63%, all 17 hand cases pass.
        var cleanQ = 46.0
        /// Margin (srcAvgQ - altAvgQ) when the alternative has dict/freq support.
        var marginSupported = 8.0
        /// Margin required on char statistics alone (typos, OOV names).
        var marginUnsupported = 26.0
        /// Frequency dominance (srcFreqQ - altFreqQ) to override a word that is
        /// itself valid-but-rare ("рун" → "hey").
        var freqDominance = 17.0
        /// Per-impossible-trigram bonus added to the source's badness.
        var impossibleBonus = 14.0
        /// Softer clean bar for alternatives explicitly present in the
        /// frequency list: brands/anglicisms whose letter patterns are alien
        /// to the language (gmail 46.4, tiktok 48.5, netflix 47.4 — all above
        /// `cleanQ`, yet unambiguous words). Zero impossible trigrams still
        /// required.
        var cleanQFreqListed = 56.0
        /// Single letters (no trigram signal): fix only when the typed char is
        /// a deep-rare standalone token (z=52, b=45, ш=56 …) and the flip is a
        /// top-frequency word (я=14, и=17, i=14 …). d(40)/c(43)/e(43) don't pass.
        var singleSourceMinQ = 45.0
        var singleTargetMaxQ = 25.0
    }

    static var thresholds = Thresholds()

    /// Decides whether exactly one alternative reading should replace the
    /// source reading. Returns the winning hypothesis id, or nil.
    static func verdict(source: Hypothesis, alternatives: [Hypothesis]) -> String? {
        let t = thresholds

        // Single letters: pure frequency bounds ("z"→"я", "ш"→"i").
        if source.core.count == 1 {
            let srcF = source.freqQ ?? 254
            guard srcF >= t.singleSourceMinQ else { return nil }
            let winners = alternatives.filter { alt in
                alt.core.count == 1 && (alt.freqQ ?? 254) <= t.singleTargetMaxQ
            }
            return winners.count == 1 ? winners.first?.id : nil
        }

        guard source.core.count >= 2 else { return nil }

        // Effective badness of what's on screen: trigram score + impossibility.
        let srcQ = (source.charAvgQ ?? 0) + Double(source.impossible) * t.impossibleBonus
        let srcSupported = source.dictValid == true || source.freqQ != nil

        var winners: [Hypothesis] = []
        for alt in alternatives {
            guard alt.core.count >= 2, alt.core != source.core else { continue }
            // Whitelist override: tech acronyms (html, css, json, png …) are
            // anti-language — impossible trigrams, no vowels — so they can
            // never pass the clean bar below no matter how obvious the fix
            // (РЕЬД→HTML). When the frequency list explicitly knows the
            // alternative, trust the list instead of the trigram bar — but
            // only against unmistakable garbage: the source is neither dict-
            // nor freq-supported AND itself contains impossible trigrams, and
            // the alt rendering is letter-for-letter (equal core length rules
            // out punctuation-stripped remnants: "жбль"→";,km"→core "km").
            // Harness: 31→67 of 77 acronyms fixed, zero new false flips on
            // 116k RU/EN typo-negatives, all hand cases unchanged.
            if !srcSupported, source.impossible >= 1, alt.freqQ != nil,
               alt.core.count == source.core.count {
                winners.append(alt)
                continue
            }
            // The target must read as genuinely clean text in its language —
            // or be a word the frequency list explicitly knows (anglicisms).
            guard let altAvg = alt.charAvgQ, alt.impossible == 0 else { continue }
            let cleanBar = alt.freqQ != nil ? t.cleanQFreqListed : t.cleanQ
            guard altAvg <= cleanBar else { continue }
            let altSupported = alt.dictValid == true || alt.freqQ != nil
            let margin = srcQ - altAvg

            if srcSupported {
                // The typed word is real too — only frequency dominance plus
                // clean statistics may override it (hey vs рун).
                guard altSupported,
                      let sf = source.freqQ ?? (source.dictValid == true ? 254 : nil),
                      let af = alt.freqQ,
                      sf - af >= t.freqDominance,
                      margin >= 0 else { continue }
                winners.append(alt)
            } else {
                // The typed word is not a known word: statistics decide.
                if altSupported && margin >= t.marginSupported {
                    winners.append(alt)
                } else if margin >= t.marginUnsupported {
                    winners.append(alt)   // typo/OOV flip: chars alone say it
                }
            }
        }
        // Several layouts can render the SAME fixed text (EN and ES layouts
        // share the latin letters) — that is one correction, not ambiguity.
        // Without this, users with three layouts got a tie → nil for nearly
        // every latin word. The ambiguity guard below stays for genuinely
        // different renderings.
        if winners.count > 1, Set(winners.map(\.core)).count == 1 {
            let best = winners.min { l, r in
                let lListed = l.freqQ != nil, rListed = r.freqQ != nil
                if lListed != rListed { return lListed } // freq-listed wins
                return (l.charAvgQ ?? 255) < (r.charAvgQ ?? 255)
            }
            return best?.id
        }
        return winners.count == 1 ? winners.first?.id : nil
    }

    /// Extracts the single letter run of a rendered window: leading/trailing
    /// non-letters are stripped; an internal non-letter disqualifies the
    /// hypothesis (returns nil) since the window would not be one word.
    static func coreExtract(_ rendered: String) -> String? {
        let trimmed = rendered.drop(while: { !$0.isLetter })
        let core = trimmed.reversed().drop(while: { !$0.isLetter }).reversed()
        guard !core.isEmpty, core.allSatisfy({ $0.isLetter }) else { return nil }
        return String(core)
    }
}
