import Foundation

// MARK: - Per-session formatting briefing
//
// The gateway offers no system-prompt API (`memory_write_api` is off on
// stock servers — Hermes-API-Fixtures.md), and every always-on channel the
// agent does have is the wrong shape: SOUL.md rides in EVERY turn of EVERY
// surface (Telegram pays for rules it never uses), while skills and memory
// are pull-mechanics — the agent may simply not fetch them for an ordinary
// reply. So the rules ride per session instead: an invisible tagged preamble
// prefixed to OUR FIRST message in each gateway session. Costs ~350 tokens
// once per Cuate session, other surfaces unaffected; the local bubble shows
// only the user's text, and the mirror sync strips the tag when the row
// comes back from the gateway (`stripped`).

enum HermesBriefing {
    static let openTag = "<cuate-briefing>"
    static let closeTag = "</cuate-briefing>"

    /// English regardless of the UI language: the rules describe syntax, not
    /// prose. The closing line scopes them out of the session's OTHER
    /// surfaces (a Cuate session can be continued from Telegram).
    static let preamble = """
    <cuate-briefing>
    You are being talked to through Cuate, a macOS app with full Markdown rendering. \
    In this session:
    - Use Markdown formatting directly in every ordinary reply: logical headings, short \
    paragraphs, lists, **bold** for emphasis, *italics* where appropriate, `inline code` \
    for commands, paths, IDs and other values meant to be copied, Markdown links, > quotes, \
    tables, and code blocks where they fit. Never answer with a plain unformatted wall of \
    text, and never wrap an ordinary reply in a document card.
    - Use the dedicated formats only for their purpose: a complete self-contained \
    interactive — as one ```html code block; a diagram — as one ```mermaid code block; a \
    README, report, article, or spec meant to be saved as a file — full content in one \
    ```markdown code block, first line `# Title`.
    - When asked to edit a previously issued HTML or Markdown document, re-issue the \
    complete updated version, not a fragment or a diff.
    - If this session is continued in Telegram or another channel, format there per that \
    channel's capabilities instead.
    </cuate-briefing>
    """

    /// The wire text of a briefed send.
    static func prefixed(_ text: String) -> String {
        preamble + "\n\n" + text
    }

    /// Removes a briefing block riding at the head of a gateway transcript
    /// row (any version — matched by tags, not content), so mirror-sync text
    /// matching and rebuilt bubbles see the user's own words. Text without a
    /// leading block passes through untouched.
    static func stripped(_ text: String) -> String {
        guard let open = text.range(of: openTag),
              text[..<open.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let close = text.range(of: closeTag, range: open.upperBound..<text.endIndex)
        else { return text }
        return String(text[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
