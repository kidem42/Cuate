import Foundation

/// A bounded rendered window containing a pinned row already loaded in memory.
nonisolated enum TranscriptNavigationWindow {
    static func range(target: Int, total: Int, pageSize: Int) -> Range<Int>? {
        guard total > 0, pageSize > 0, (0..<total).contains(target) else { return nil }
        let count = min(total, pageSize)
        let start = min(max(0, target - min(5, count - 1)), total - count)
        return start..<(start + count)
    }
    /// Indices arrive newest-first; ties keep the newest candidate.
    static func nearestPin(positions: [Int], anchor: Int) -> Int? {
        positions.indices.min { abs(positions[$0] - anchor) < abs(positions[$1] - anchor) }
    }
}
