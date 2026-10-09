import Testing
@testable import dBrief

@Suite("Library keyboard navigation")
struct LibraryKeyboardNavigationTests {
    private let ids = ["a", "b", "c"]

    @Test func arrowsStepThroughTheVisibleList() {
        #expect(LibraryKeyboardNavigation.step(ids, from: "b", by: 1) == "c")
        #expect(LibraryKeyboardNavigation.step(ids, from: "b", by: -1) == "a")
    }

    @Test func endsOfTheListStayPut() {
        #expect(LibraryKeyboardNavigation.step(ids, from: "c", by: 1) == nil)
        #expect(LibraryKeyboardNavigation.step(ids, from: "a", by: -1) == nil)
    }

    @Test func withoutAVisibleSelectionDownPicksFirstAndUpPicksLast() {
        #expect(LibraryKeyboardNavigation.step(ids, from: nil, by: 1) == "a")
        #expect(LibraryKeyboardNavigation.step(ids, from: "hidden", by: -1) == "c")
        #expect(LibraryKeyboardNavigation.step([String](), from: nil, by: 1) == nil)
    }

    @Test func deletingSelectsTheNextRowThenThePreviousOne() {
        #expect(LibraryKeyboardNavigation.successor(of: "b", in: ids) == "c")
        #expect(LibraryKeyboardNavigation.successor(of: "c", in: ids) == "b")
        #expect(LibraryKeyboardNavigation.successor(of: "a", in: ["a"]) == nil)
        #expect(LibraryKeyboardNavigation.successor(of: "x", in: ids) == nil)
    }
}
