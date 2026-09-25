import Foundation

/// A history-compaction trigger, not a hard ceiling on complete API requests.
nonisolated enum ContextCompressionPolicy {
    static let defaultThreshold = 7_000
    static let range = 1_000...200_000

    static func normalized(_ value: Int) -> Int {
        min(range.upperBound, max(range.lowerBound, value))
    }

    static func threshold(global: Int, override: Int?) -> Int {
        normalized(override ?? global)
    }
    /// Reject malformed, empty, unexpected or structurally truncated notes.
    /// Provider completion and size checks are separate, required gates.
    static func validatedSummary(_ text: String) -> String? {
        guard let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["facts", "decisions", "preferences", "openTasks"])
        else { return nil }
        var sections: [String] = []
        for (key, heading) in [("facts", "Facts"), ("decisions", "Decisions"),
                               ("preferences", "User preferences"), ("openTasks", "Open tasks")] {
            guard let items = object[key] as? [String],
                  items.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            if !items.isEmpty { sections.append(heading + ":\n" + items.map { "- " + $0 }.joined(separator: "\n")) }
        }
        return sections.isEmpty ? nil : sections.joined(separator: "\n\n")
    }
}
