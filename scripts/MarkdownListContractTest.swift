import Foundation

// Contract test for the markdown LIST parser — numbering, nesting and the
// continuation lines that used to end a list. Compiled STANDALONE against a
// copy of the tree builder's inputs, so it needs no app target:
//   swiftc MarkdownListContractTest.swift -o test && ./test
//
// It exercises `MarkdownBlocksView.buildListBlocks` through a thin mirror of
// the surrounding parse loop: the loop's job is only to classify lines and
// hand them over, which is exactly what `classify` does here. Keep the two in
// sync when the collector in MarkdownBlocksView.parse changes.

// MARK: - The shapes under test (mirrors MarkdownBlocksView)

struct ListItem {
    let text: String
    let children: [Block]
    init(_ text: String, children: [Block] = []) {
        self.text = text
        self.children = children
    }
}

struct TaskItem {
    let checked: Bool
    let text: String
    let children: [Block]
}

indirect enum Block {
    case paragraph(String)
    case bullets([ListItem])
    case numbered(start: Int, items: [ListItem])
    case tasks([TaskItem])
}

struct RawListLine {
    enum Kind: Equatable {
        case bullet
        case numbered(Int)
        case task(Bool)
        case text
        var family: Int {
            switch self {
            case .bullet: return 0
            case .numbered: return 1
            case .task: return 2
            case .text: return 3
            }
        }
    }
    let indent: Int
    let contentIndent: Int
    let kind: Kind
    let text: String
}

func buildListBlocks(_ lines: [RawListLine]) -> [Block] {
    guard !lines.isEmpty else { return [] }
    let base = lines.map(\.indent).min() ?? 0
    var blocks: [Block] = []
    var index = 0
    while index < lines.count {
        let family = lines[index].kind.family
        var bullets: [ListItem] = []
        var tasks: [TaskItem] = []
        var prose: [String] = []
        var start: Int?
        while index < lines.count, lines[index].indent <= base,
              lines[index].kind.family == family {
            let line = lines[index]
            index += 1
            var childLines: [RawListLine] = []
            while index < lines.count, lines[index].indent > base {
                childLines.append(lines[index])
                index += 1
            }
            let children = buildListBlocks(childLines)
            switch line.kind {
            case .bullet:
                bullets.append(ListItem(line.text, children: children))
            case .numbered(let number):
                if start == nil { start = number }
                bullets.append(ListItem(line.text, children: children))
            case .task(let checked):
                tasks.append(TaskItem(checked: checked, text: line.text, children: children))
            case .text:
                prose.append(line.text)
            }
        }
        switch family {
        case 0 where !bullets.isEmpty: blocks.append(.bullets(bullets))
        case 1 where !bullets.isEmpty: blocks.append(.numbered(start: start ?? 1, items: bullets))
        case 2 where !tasks.isEmpty: blocks.append(.tasks(tasks))
        case 3 where !prose.isEmpty: blocks.append(.paragraph(prose.joined(separator: "\n")))
        default: break
        }
    }
    return blocks
}

// MARK: - The collector (mirrors the list branch of parse)

func classify(_ markdown: String) -> [Block] {
    var lines: [RawListLine] = []
    for rawLine in markdown.components(separatedBy: "\n") {
        let indent = rawLine.prefix { $0 == " " || $0 == "\t" }
            .reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { continue }

        func task(_ line: String) -> (Bool, String)? {
            guard line.hasPrefix("- [") || line.hasPrefix("* [") else { return nil }
            let rest = line.dropFirst(2)
            guard rest.count > 4 else { return nil }
            switch rest.prefix(4).lowercased() {
            case "[ ] ": return (false, String(rest.dropFirst(4)))
            case "[x] ": return (true, String(rest.dropFirst(4)))
            default: return nil
            }
        }
        func numbered(_ line: String) -> (Int, String)? {
            let digits = line.prefix(while: { $0.isNumber })
            guard !digits.isEmpty, digits.count <= 3, let number = Int(digits) else { return nil }
            let rest = line.dropFirst(digits.count)
            guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
            return (number, String(rest.dropFirst(2)))
        }

        if let (checked, text) = task(trimmed) {
            lines.append(RawListLine(indent: indent, contentIndent: indent + (trimmed.count - text.count),
                                     kind: .task(checked), text: text))
        } else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("• ")
                    || trimmed.hasPrefix("+ ") {
            lines.append(RawListLine(indent: indent, contentIndent: indent + 2,
                                     kind: .bullet, text: String(trimmed.dropFirst(2))))
        } else if let (number, text) = numbered(trimmed) {
            lines.append(RawListLine(indent: indent, contentIndent: indent + (trimmed.count - text.count),
                                     kind: .numbered(number), text: text))
        } else if !lines.isEmpty, indent >= 2,
                  let owner = lines.lastIndex(where: { $0.contentIndent <= indent }) {
            lines.append(RawListLine(indent: lines[owner].contentIndent,
                                     contentIndent: lines[owner].contentIndent,
                                     kind: .text, text: trimmed))
        }
    }
    return buildListBlocks(lines)
}

// MARK: - Readable rendering of the result, for assertions

func describe(_ blocks: [Block], depth: Int = 0) -> [String] {
    var out: [String] = []
    let pad = String(repeating: "  ", count: depth)
    for block in blocks {
        switch block {
        case .paragraph(let text):
            out.append("\(pad)P \(text)")
        case .bullets(let items):
            for item in items {
                out.append("\(pad)• \(item.text)")
                out += describe(item.children, depth: depth + 1)
            }
        case .numbered(let start, let items):
            for (index, item) in items.enumerated() {
                out.append("\(pad)\(start + index). \(item.text)")
                out += describe(item.children, depth: depth + 1)
            }
        case .tasks(let items):
            for item in items {
                out.append("\(pad)\(item.checked ? "[x]" : "[ ]") \(item.text)")
                out += describe(item.children, depth: depth + 1)
            }
        }
    }
    return out
}

// MARK: - Cases

let cases: [(name: String, markdown: String, expected: [String])] = [
    (
        "sub-bullets do not restart the numbering",
        """
        1. Tier 4 SCR
           - cost: $400k
           - integration: $50k
        2. Configuration
           - one 3.3 MW unit
        3. Certification
        """,
        ["1. Tier 4 SCR", "  • cost: $400k", "  • integration: $50k",
         "2. Configuration", "  • one 3.3 MW unit", "3. Certification"]
    ),
    (
        "all-ones renumber per CommonMark",
        """
        1. first
        1. second
        1. third
        """,
        ["1. first", "2. second", "3. third"]
    ),
    (
        "a list starting at three keeps counting from three",
        """
        3. third
        4. fourth
        """,
        ["3. third", "4. fourth"]
    ),
    (
        "an indented paragraph continues its item",
        """
        1. Configuration
           - option A
           Compare cost, cooling and noise.
        2. Price
        """,
        ["1. Configuration", "  • option A", "  P Compare cost, cooling and noise.", "2. Price"]
    ),
    (
        "three levels deep",
        """
        1. one
           - two
             - three
        2. next
        """,
        ["1. one", "  • two", "    • three", "2. next"]
    ),
    (
        "a bullet run after a numbered run is its own list",
        """
        1. numbered
        2. numbered two
        - bullet
        - bullet two
        """,
        ["1. numbered", "2. numbered two", "• bullet", "• bullet two"]
    ),
    (
        "bullets nest three levels without any numbering",
        """
        - top
          - middle
            - deep
        - second top
        """,
        ["• top", "  • middle", "    • deep", "• second top"]
    ),
    (
        "a bullet keeps its continuation line",
        """
        - option A
          Cheaper, but louder.
        - option B
        """,
        ["• option A", "  P Cheaper, but louder.", "• option B"]
    ),
    (
        "mixed - and * markers stay one list",
        """
        - dash
        * star
        + plus
        """,
        ["• dash", "• star", "• plus"]
    ),
    (
        "a numbered sub-list under a bullet counts from its own start",
        """
        - preparation
          1. measure
          1. cut
        - assembly
        """,
        ["• preparation", "  1. measure", "  2. cut", "• assembly"]
    ),
    (
        "italics at line start are not a bullet",
        """
        *emphasis* leads the line
        - real bullet
        """,
        ["• real bullet"]
    ),
    (
        "tasks keep their boxes and nest",
        """
        - [ ] open
          - [x] done sub
        - [x] closed
        """,
        ["[ ] open", "  [x] done sub", "[x] closed"]
    ),
    (
        "four-space and tab indentation both nest",
        """
        1. one
            - four spaces
        2. two
        \t- a tab
        """,
        ["1. one", "  • four spaces", "2. two", "  • a tab"]
    ),
    (
        "a blank line inside a list does not split it",
        """
        1. one

        2. two
        """,
        ["1. one", "2. two"]
    ),
]

var failures = 0
for testCase in cases {
    let got = describe(classify(testCase.markdown))
    if got != testCase.expected {
        failures += 1
        print("FAIL [\(testCase.name)]")
        print("  got:")
        got.forEach { print("    \($0)") }
        print("  want:")
        testCase.expected.forEach { print("    \($0)") }
    }
}
if failures == 0 {
    print("swift: all green (\(cases.count) cases)")
} else {
    print("swift: \(failures) failure(s) across \(cases.count) cases")
    exit(1)
}
