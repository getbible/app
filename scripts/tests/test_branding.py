"""Keep duplicate native declarations and localized branding under one gate."""
import importlib.util
from pathlib import Path
import unittest


SPEC = importlib.util.spec_from_file_location(
    "branding", Path(__file__).resolve().parents[1] / "check_branding.py"
)
branding = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(branding)


class BrandingTests(unittest.TestCase):
    def test_current_repository_has_one_product_identity(self):
        self.assertEqual(branding.validate(branding.ROOT), [])

    def test_retired_labels_and_identifiers_are_rejected(self):
        for value in ("getBible." + "live", "getBible." + "Life",
                      "getbible_" + "live", "getbible_" + "life",
                      "getbible-" + "live", "native.getbible" + "Life"):
            with self.subTest(value=value):
                self.assertEqual(len(branding.text_violations("example", value)), 1)

    def test_reference_site_and_repository_remain_valid(self):
        for value in ("https://app.getbible.life/KJV/John/3?verse=16",
                      "https://github.com/getbible/app.getbible.life",
                      "life.getbible.mobile", "getBible", "getbible"):
            with self.subTest(value=value):
                self.assertEqual(branding.text_violations("example", value), [])

    def test_documentation_keeps_exact_product_spelling(self):
        for value in ("GetBible", "Get Bible", "get Bible", "GETBIBLE"):
            with self.subTest(value=value):
                self.assertEqual(
                    len(branding.text_violations("docs/BRANDING.md", value)), 1
                )
        self.assertEqual(branding.text_violations(
            "README.md", "getBible uses getbible packages and GETBIBLE_ENV."
        ), [])

    def test_native_error_text_keeps_brand_without_renaming_classes(self):
        self.assertEqual(branding.text_violations(
            "lib/core/errors.dart", "throw Error('GetBible is unavailable.');"
        ), ["lib/core/errors.dart:1: display text must use getBible"])
        self.assertEqual(branding.text_violations(
            "lib/application/app_state.dart",
            "final GetBibleApiClient client = GetBibleApiClient();"
        ), [])
        self.assertEqual(branding.text_violations(
            "lib/core/errors.dart", 'throw Error("getBible is unavailable.");'
        ), [])


if __name__ == "__main__":
    unittest.main()
