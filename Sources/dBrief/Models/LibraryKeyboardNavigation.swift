import Foundation

/// Arrow-key and delete movement through the library sidebar's visible rows.
enum LibraryKeyboardNavigation {
    /// The row `offset` away from `current`, or `nil` at either end. With no
    /// visible selection, down starts at the top and up at the bottom.
    static func step<ID: Equatable>(_ ids: [ID], from current: ID?, by offset: Int) -> ID? {
        guard !ids.isEmpty else { return nil }
        guard let current, let index = ids.firstIndex(of: current) else {
            return offset >= 0 ? ids.first : ids.last
        }
        let target = index + offset
        return ids.indices.contains(target) ? ids[target] : nil
    }

    /// The row to select once `removed` is deleted: the next one, else the previous.
    static func successor<ID: Equatable>(of removed: ID, in ids: [ID]) -> ID? {
        guard let index = ids.firstIndex(of: removed) else { return nil }
        if ids.indices.contains(index + 1) { return ids[index + 1] }
        return index > 0 ? ids[index - 1] : nil
    }
}
