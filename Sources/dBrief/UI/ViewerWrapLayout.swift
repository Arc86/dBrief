import SwiftUI

/// Lays its children out on one row when they fit and wraps them onto more rows
/// when they don't. It replaces `ViewThatFits` in the viewer chrome:
/// `ViewThatFits` keeps every candidate arrangement alive, so each menu, popover
/// and `.task` inside it existed two or three times and was rebuilt on every
/// layout pass. Here each child exists once.
///
/// With `pinsLastToTrailing`, the last child sits at the trailing edge: on the
/// first row when everything fits, otherwise on its own final row.
struct ViewerWrapLayout: Layout {
    enum RowAlignment { case leading, trailing }

    var alignment: RowAlignment = .leading
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8
    var pinsLastToTrailing = false

    struct Cache {
        var sizes: [CGSize]
    }

    func makeCache(subviews: Subviews) -> Cache {
        Cache(sizes: subviews.map { $0.sizeThatFits(.unspecified) })
    }

    func updateCache(_ cache: inout Cache, subviews: Subviews) {
        cache = makeCache(subviews: subviews)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
        let rows = Self.rows(sizes: cache.sizes, width: proposal.width, spacing: spacing, pinsLast: pinsLastToTrailing)
        let height = rows.enumerated().reduce(CGFloat(0)) { total, row in
            total + (row.offset > 0 ? lineSpacing : 0) + Self.height(of: row.element, sizes: cache.sizes)
        }
        let widest = rows.map { Self.width(of: $0, sizes: cache.sizes, spacing: spacing) }.max() ?? 0
        // Fill a concrete width (the rows align inside it); report the ideal otherwise.
        let width = proposal.width.map { $0.isFinite ? $0 : widest } ?? widest
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
        let rows = Self.rows(sizes: cache.sizes, width: bounds.width, spacing: spacing, pinsLast: pinsLastToTrailing)
        let last = subviews.count - 1
        var y = bounds.minY
        for row in rows {
            let rowHeight = Self.height(of: row, sizes: cache.sizes)
            let rowWidth = Self.width(of: row, sizes: cache.sizes, spacing: spacing)
            var x = alignment == .trailing ? bounds.maxX - rowWidth : bounds.minX
            for index in row {
                let size = cache.sizes[index]
                if pinsLastToTrailing, index == last { x = bounds.maxX - size.width }
                subviews[index].place(at: CGPoint(x: x, y: y + (rowHeight - size.height) / 2),
                                      proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += rowHeight + lineSpacing
        }
    }

    /// Greedy rows of subview indices for `width` (nil or infinite: one row).
    static func rows(sizes: [CGSize], width: CGFloat?, spacing: CGFloat, pinsLast: Bool) -> [Range<Int>] {
        guard !sizes.isEmpty else { return [] }
        let all = 0..<sizes.count
        guard let width, width.isFinite,
              Self.width(of: all, sizes: sizes, spacing: spacing) > width else { return [all] }
        let flowing = pinsLast ? 0..<(sizes.count - 1) : all
        var rows: [Range<Int>] = []
        var start = flowing.lowerBound
        var rowWidth: CGFloat = 0
        for index in flowing {
            let added = (index > start ? spacing : 0) + sizes[index].width
            if index > start, rowWidth + added > width {
                rows.append(start..<index)
                start = index
                rowWidth = sizes[index].width
            } else {
                rowWidth += added
            }
        }
        if start < flowing.upperBound { rows.append(start..<flowing.upperBound) }
        if pinsLast { rows.append((sizes.count - 1)..<sizes.count) }
        return rows
    }

    private static func width(of row: Range<Int>, sizes: [CGSize], spacing: CGFloat) -> CGFloat {
        row.reduce(CGFloat(0)) { $0 + sizes[$1].width } + spacing * CGFloat(max(row.count - 1, 0))
    }

    private static func height(of row: Range<Int>, sizes: [CGSize]) -> CGFloat {
        row.map { sizes[$0].height }.max() ?? 0
    }
}
