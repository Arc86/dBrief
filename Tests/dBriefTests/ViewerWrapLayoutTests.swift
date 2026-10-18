import CoreGraphics
import Testing
@testable import dBrief

@Suite("Viewer wrap layout rows")
struct ViewerWrapLayoutTests {
    private let sizes = [CGSize(width: 100, height: 30), CGSize(width: 80, height: 30),
                         CGSize(width: 60, height: 30), CGSize(width: 50, height: 30)]

    @Test("Everything on one row when it fits, or with no width")
    func singleRow() {
        // 100 + 80 + 60 + 50 + 3 × 8 = 314
        #expect(ViewerWrapLayout.rows(sizes: sizes, width: 314, spacing: 8, pinsLast: false) == [0..<4])
        #expect(ViewerWrapLayout.rows(sizes: sizes, width: nil, spacing: 8, pinsLast: true) == [0..<4])
        #expect(ViewerWrapLayout.rows(sizes: sizes, width: .infinity, spacing: 8, pinsLast: false) == [0..<4])
    }

    @Test("Wraps greedily when too narrow")
    func wraps() {
        #expect(ViewerWrapLayout.rows(sizes: sizes, width: 200, spacing: 8, pinsLast: false) == [0..<2, 2..<4])
        #expect(ViewerWrapLayout.rows(sizes: sizes, width: 90, spacing: 8, pinsLast: false) == [0..<1, 1..<2, 2..<3, 3..<4])
    }

    @Test("The pinned last item gets its own row once anything wraps")
    func pinnedLast() {
        #expect(ViewerWrapLayout.rows(sizes: sizes, width: 300, spacing: 8, pinsLast: true) == [0..<3, 3..<4])
        #expect(ViewerWrapLayout.rows(sizes: sizes, width: 200, spacing: 8, pinsLast: true) == [0..<2, 2..<3, 3..<4])
    }

    @Test("No children, no rows")
    func empty() {
        #expect(ViewerWrapLayout.rows(sizes: [], width: 100, spacing: 8, pinsLast: true).isEmpty)
    }
}
