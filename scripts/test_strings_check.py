import importlib.util
import io
import json
import pathlib
import tempfile
import unittest
from contextlib import redirect_stdout


SPEC = importlib.util.spec_from_file_location("strings_check", pathlib.Path(__file__).with_name("strings_check.py"))
strings_check = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(strings_check)


def unit(value, state="translated"):
    return {"stringUnit": {"state": state, "value": value}}


class SpecifierTests(unittest.TestCase):
    def test_same_specifiers_pass(self):
        self.assertIsNone(strings_check.spec_problem("Delete %@ older than %@?", "%@ ouder dan %@ verwijderen?"))

    def test_missing_or_wrong_specifier_fails(self):
        self.assertIsNotNone(strings_check.spec_problem("Recovered %lld recordings", "Opnamen hersteld"))
        self.assertIsNotNone(strings_check.spec_problem("Recovered %lld recordings", "%@ opnamen hersteld"))

    def test_positional_specifiers_may_reorder(self):
        self.assertIsNone(strings_check.spec_problem("%@ of %lld", "%2$lld van %1$@"))
        self.assertIsNotNone(strings_check.spec_problem("%@ of %lld", "%2$lld van %@"))

    def test_plural_variant_may_drop_the_number(self):
        key = "Name the %lld voices before the analysis continues."
        self.assertIsNone(strings_check.spec_problem(key, "Name the voice before the analysis continues.", variant=True))
        self.assertIsNotNone(strings_check.spec_problem(key, "Name %@ voices", variant=True))

    def test_percent_in_prose_is_not_a_specifier(self):
        self.assertIsNone(strings_check.spec_problem("WER of 6.05% for v2", "WER van 6,05% voor v2"))

    def test_untranslatable_keys(self):
        self.assertFalse(strings_check.translatable("%@ · %@"))
        self.assertTrue(strings_check.translatable("%lld words"))


class CatalogTests(unittest.TestCase):
    def catalog(self, nl):
        return {"sourceLanguage": "en", "strings": {
            "%lld words": {"localizations": {"nl": nl}},
            "Copy": {"localizations": {"nl": unit("Kopieer", "needs_review")}},
            "%@ · %@": {},
            "Old": {"extractionState": "stale", "localizations": {}},
        }}

    def test_broken_translation_is_reported(self):
        problems = strings_check.check_translations(self.catalog(unit("woorden")))
        self.assertEqual(len(problems), 1)
        self.assertIn("%lld words", problems[0])

    def test_plural_variants_are_checked(self):
        good = {"variations": {"plural": {"one": unit("%lld woord"), "other": unit("%lld woorden")}}}
        bad = {"variations": {"plural": {"one": unit("%@ woord"), "other": unit("%lld woorden")}}}
        self.assertEqual(strings_check.check_translations(self.catalog(good)), [])
        self.assertEqual(len(strings_check.check_translations(self.catalog(bad))), 1)

    def test_report_counts_translatable_live_keys(self):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "Localizable.xcstrings"
            path.write_text(json.dumps(self.catalog(unit("%lld woorden"))))
            output = io.StringIO()
            with redirect_stdout(output):
                strings_check.report(str(path))
        self.assertIn("| nl | 2/2 (100%) | 1 | 0 |", output.getvalue())


if __name__ == "__main__":
    unittest.main()
