import Foundation

/// Paths taken from a TOOL CALL's arguments — the only place in an agent
/// turn where a filename is data instead of prose.
///
/// The chat channel carries text (notes §7.2 items 6–7), which is why paths
/// were read out of the reply at all. But the tool calls behind that reply
/// are structured and they already reach us: `tool.started` ships its `args`
/// dict live, and the transcript keeps `tool_calls[].function.arguments` for
/// good. Hermes' own file tools name the argument `path` and take it
/// "absolute, relative, or ~/path" (`tools/file_tools.py`), so a file the
/// agent wrote, read or edited is knowable EXACTLY, with no guess at all.
///
/// Key names are not assumed: a value is taken when its key looks like a
/// path key OR the value itself looks like a path. Tools come from plugins
/// and skills too, and their argument names are theirs to choose.
enum AgentToolPaths {

    /// Argument keys that name a path in Hermes' own tools and in the
    /// plugin tools seen so far. Matched as substrings, case-insensitively.
    private static let pathKeyHints = ["path", "file", "dir", "dest", "target", "output", "source"]

    /// Extracts every path-looking value from a tool's arguments. Nested
    /// dicts and arrays are walked (an edit tool takes a list of edits, each
    /// with its own path), bounded in depth and count.
    static func extract(fromArguments arguments: Any?) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        walk(arguments, key: nil, depth: 0, seen: &seen, found: &found)
        return found
    }

    /// Same, for the raw JSON string the transcript stores for a call.
    static func extract(fromJSON raw: String) -> [String] {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
        return extract(fromArguments: object)
    }

    private static func walk(_ value: Any?, key: String?, depth: Int,
                             seen: inout Set<String>, found: inout [String]) {
        guard depth <= 3, found.count < 8 else { return }
        switch value {
        case let text as String:
            guard let path = path(from: text, key: key), seen.insert(path).inserted else { return }
            found.append(path)
        case let list as [Any]:
            for item in list { walk(item, key: key, depth: depth + 1, seen: &seen, found: &found) }
        case let dict as [String: Any]:
            // Sorted so the same call always yields the same order — the
            // chip row must not reshuffle between renders.
            for (subKey, subValue) in dict.sorted(by: { $0.key < $1.key }) {
                walk(subValue, key: subKey, depth: depth + 1, seen: &seen, found: &found)
            }
        default:
            return
        }
    }

    /// A value is a path when its key says so, or when it is shaped like
    /// one. Deliberately strict about shape: file CONTENT arrives as a
    /// string too, and a whole document must never be mistaken for a name.
    private static func path(from raw: String, key: String?) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 1024,
              !text.contains("\n"), !text.contains("\r"), !text.contains("\0"),
              !text.contains("://")
        else { return nil }

        let keyLooksLikePath = (key?.lowercased()).map { lowered in
            pathKeyHints.contains { lowered.contains($0) }
        } ?? false
        let absolute = text.hasPrefix("/") || text.hasPrefix("~/")
        let relative = text.contains("/") || (text as NSString).pathExtension.isEmpty == false

        guard absolute || (keyLooksLikePath && relative) else { return nil }
        // "." and "/" as a search root are not files anyone downloads.
        guard text != ".", text != "/", text != "~", text != "./" else { return nil }
        return text
    }
}
