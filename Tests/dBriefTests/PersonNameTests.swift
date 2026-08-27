import Foundation
import Testing
@testable import dBrief

struct PersonNameTests {

    // MARK: - "Last, First" normalization

    @Test
    func flipsDirectoryStyleLastCommaFirst() {
        #expect(PersonName.display("den Boer, Bart") == "Bart den Boer")
        #expect(PersonName.display("De Roni, Marco") == "Marco De Roni")
        #expect(PersonName.display("Mol, Jesper") == "Jesper Mol")
    }

    @Test
    func leavesPlainNamesUntouched() {
        #expect(PersonName.display("Jesper Mol") == "Jesper Mol")
        #expect(PersonName.display("Alice") == "Alice")
    }

    @Test
    func trimsAndCollapsesWhitespace() {
        #expect(PersonName.display("  Jesper   Mol  ") == "Jesper Mol")
        #expect(PersonName.display("Boer,   Bart") == "Bart Boer")
    }

    /// A generational/professional suffix after the comma is not a given name — joining it
    /// in reverse ("Jr. John Smith") would be wrong, so keep source order.
    @Test
    func keepsOrderForNameSuffixes() {
        #expect(PersonName.display("John Smith, Jr.") == "John Smith Jr.")
        #expect(PersonName.display("Jane Doe, PhD") == "Jane Doe PhD")
        #expect(PersonName.display("Henry Ford, III") == "Henry Ford III")
    }

    /// More than one comma isn't a "Last, First" pair — don't guess, just clean it up.
    @Test
    func multipleCommasAreOnlyCleaned() {
        #expect(PersonName.display("Boer, Bart, den") == "Boer Bart den")
    }

    @Test
    func handlesEmptyAndCommaOnlyInput() {
        #expect(PersonName.display("") == "")
        #expect(PersonName.display("   ") == "")
        #expect(PersonName.display(",") == "")
        #expect(PersonName.display("Boer,") == "Boer")
        #expect(PersonName.display(", Bart") == "Bart")
    }

    /// Emails are used as the fallback display name when a calendar gives no name;
    /// they must survive untouched.
    @Test
    func leavesEmailAddressesIntact() {
        #expect(PersonName.display("bart@acme.com") == "bart@acme.com")
    }

    // MARK: - list cleanup

    @Test
    func listTrimsDropsEmptiesAndDedupesCaseInsensitively() {
        let out = PersonName.displayList(["den Boer, Bart", "  ", "Bart den Boer", "Alice", "alice"])
        #expect(out == ["Bart den Boer", "Alice"])
    }

    // MARK: - typed input

    /// A human typing a comma is listing people ("Alice, Bob"), unlike a directory calendar
    /// where the comma is part of one name — so typed input splits and is never reordered.
    @Test
    func typedNamesSplitOnCommas() {
        #expect(PersonName.typedNames("Alice, Bob") == ["Alice", "Bob"])
        #expect(PersonName.typedNames("Alice,Bob ,  Carol") == ["Alice", "Bob", "Carol"])
    }

    @Test
    func typedNamesKeepASingleNameIntact() {
        #expect(PersonName.typedNames("  Jesper   Mol ") == ["Jesper Mol"])
        #expect(PersonName.typedNames("") == [])
        #expect(PersonName.typedNames(" , ") == [])
    }

    @Test
    func typedNamesDedupeCaseInsensitively() {
        #expect(PersonName.typedNames("Alice, alice, Bob") == ["Alice", "Bob"])
    }

    // MARK: - editing one entry of a participant list

    @Test
    func replacingEditsInPlaceKeepingPosition() {
        let out = PersonName.replacing("Bart", in: ["Jesper", "Bart", "Marco"], with: "Bart den Boer")
        #expect(out == ["Jesper", "Bart den Boer", "Marco"])
    }

    /// Editing one pill is a single-name context, so a comma there is the directory form.
    @Test
    func replacingNormalizesDirectoryStyleInput() {
        let out = PersonName.replacing("Bart", in: ["Bart"], with: "den Boer, Bart")
        #expect(out == ["Bart den Boer"])
    }

    @Test
    func replacingIgnoresBlankInput() {
        let names = ["Jesper", "Bart"]
        #expect(PersonName.replacing("Bart", in: names, with: "   ") == names)
    }

    @Test
    func replacingIgnoresAnUnknownEntry() {
        let names = ["Jesper", "Bart"]
        #expect(PersonName.replacing("Nobody", in: names, with: "Someone") == names)
    }

    /// Renaming onto a name that's already in the list merges rather than duplicating.
    @Test
    func replacingOntoAnExistingNameDeDupes() {
        let out = PersonName.replacing("Bart", in: ["Jesper", "Bart", "Marco"], with: "marco")
        #expect(out == ["Jesper", "Marco"])
    }

    /// Re-committing the same name (or a case variant of it) is a no-op, not a removal.
    @Test
    func replacingWithItsOwnNameKeepsTheEntry() {
        #expect(PersonName.replacing("Bart", in: ["Jesper", "Bart"], with: "Bart") == ["Jesper", "Bart"])
        #expect(PersonName.replacing("Bart", in: ["Jesper", "Bart"], with: "BART") == ["Jesper", "BART"])
    }

    @Test
    func replacingMatchesTheEditedEntryCaseInsensitively() {
        #expect(PersonName.replacing("bart", in: ["Bart"], with: "Bart den Boer") == ["Bart den Boer"])
    }
}
