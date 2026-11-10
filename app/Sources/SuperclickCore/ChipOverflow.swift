import Foundation

/// Context chips stay on one line (DECISIONS, mockup round 4). Chips that don't
/// fit tuck, from the end, into a stack of overlapping icons with a count.
/// Pinned chips (the "secret redacted" chip) never tuck.
public enum ChipOverflow {
    public struct Result: Equatable, Sendable {
        public var visible: [Int]
        public var tucked: [Int]
    }

    /// - Parameters:
    ///   - widths: each chip's width, in display order.
    ///   - pinned: indices that must stay visible.
    ///   - available: the row's width.
    ///   - spacing: the gap between items.
    ///   - stackWidth: the overflow stack's width for a given number of tucked chips.
    public static func layout(
        widths: [Double], pinned: Set<Int>, available: Double, spacing: Double,
        stackWidth: (Int) -> Double
    ) -> Result {
        var visible = Array(widths.indices)
        var tucked: [Int] = []

        func rowWidth() -> Double {
            let items = visible.map { widths[$0] } + (tucked.isEmpty ? [] : [stackWidth(tucked.count)])
            return items.reduce(0, +) + spacing * Double(max(items.count - 1, 0))
        }

        while rowWidth() > available {
            guard let last = visible.lastIndex(where: { !pinned.contains($0) }) else { break }
            tucked.insert(visible.remove(at: last), at: 0)
        }
        return Result(visible: visible, tucked: tucked)
    }
}
