import Testing
@testable import dBrief

struct VocabularyEditingTests {
    @Test func cancellationPreservesSavedTerms() {
        var terms = ["ServiceNow", "Codex"]
        var editor = VocabularyEditing()
        editor.begin(at: 0, in: terms)
        editor.text = "Changed"
        editor.cancel()
        editor.save(in: &terms)
        #expect(terms == ["ServiceNow", "Codex"])
        #expect(!editor.isEditing)
        #expect(editor.text.isEmpty)
    }

    @Test func duplicateAndEmptyEditsRetainDraftAndOriginal() {
        var terms = ["ServiceNow", "Codex"]
        var editor = VocabularyEditing()
        editor.begin(at: 0, in: terms)
        for invalid in ["  CODEX \n", " \n "] {
            editor.text = invalid
            editor.save(in: &terms)
            #expect(terms == ["ServiceNow", "Codex"])
            #expect(editor.isEditing)
            #expect(editor.text == invalid)
            #expect(editor.error != nil)
        }
        editor.text = "  ServiceNow AI \n"
        editor.save(in: &terms)
        #expect(terms == ["ServiceNow AI", "Codex"])
        #expect(!editor.isEditing)
    }

    @Test func deletingPrecedingTermStillEditsOriginalTerm() {
        var terms = ["First", "Second", "Third"]
        var editor = VocabularyEditing()
        editor.begin(at: 1, in: terms)
        editor.text = "Updated"
        terms.remove(at: 0)
        editor.save(in: &terms)
        #expect(terms == ["Updated", "Third"])
        #expect(!editor.isEditing)
    }

    @Test func missingOrAmbiguousOriginalCannotOverwriteAnotherTerm() {
        for changedTerms in [["First", "Replacement"], ["Second", "Second"]] {
            var editor = VocabularyEditing()
            editor.begin(at: 1, in: ["First", "Second"])
            editor.text = "Updated"
            var terms = changedTerms
            editor.save(in: &terms)
            #expect(terms == changedTerms)
            #expect(editor.isEditing)
            #expect(editor.text == "Updated")
            #expect(editor.error != nil)
        }
    }

    @Test func addValidationTrimsAndRejectsDuplicates() throws {
        #expect(try VocabularyEditing.validate("  New \n", in: ["Existing"]).get() == "New")
        #expect(throws: VocabularyEditing.ValidationError.self) {
            try VocabularyEditing.validate(" EXISTING ", in: ["Existing"]).get()
        }
        #expect(throws: VocabularyEditing.ValidationError.self) {
            try VocabularyEditing.validate(" \n", in: []).get()
        }
    }
}
