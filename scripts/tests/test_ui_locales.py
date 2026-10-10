"""Offline regression tests for public-UI-only localization tooling."""
import importlib.util
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load_tool(name):
    spec = importlib.util.spec_from_file_location(name, ROOT / 'tool' / f'{name}.py')
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


inventory = load_tool('ui_locale_inventory')
translation = load_tool('translate_native_locales')


class UiLocaleToolingTest(unittest.TestCase):
    def test_checked_in_inventory_covers_literal_control_templates(self):
        inventory.generate(check=True)

    def test_plain_static_controls_cannot_silently_bypass_localization(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            widget = root / 'lib/presentation/example.dart'
            widget.parent.mkdir(parents=True)
            widget.write_text("TextField(helperText: 'Retry saving');", encoding='utf-8')
            with patch.object(inventory, 'ROOT', root):
                with self.assertRaisesRegex(ValueError, 'Retry saving'):
                    inventory.audit_static_controls()
                widget.write_text("Text(UiStrings.of(context).text('Retry saving'));",
                                  encoding='utf-8')
                inventory.audit_static_controls()

    def test_ui_templates_require_explicit_variables(self):
        with self.assertRaisesRegex(ValueError, 'named'):
            inventory.read_literal("'Downloading $resource'", 0)
        self.assertEqual(inventory.read_literal("'Downloading {name}'", 0)[0],
                         'Downloading {name}')

    def test_generated_contract_is_independent_of_dart_format(self):
        first = 'const Map<String, String> nativeUiKeys = <String, String>{"Text": "native.text",};'
        formatted = "const Map<String, String> nativeUiKeys = <String, String>{\n  'Text':\n      'native.text',\n};"
        self.assertEqual(inventory.dart_catalog(first), inventory.dart_catalog(formatted))

    def test_protection_retains_technical_terms_and_repeated_placeholders(self):
        original = 'Save {name} as UTF-8 JSON or Markdown; {name} requires {count} MiB.'
        protected, replacements = translation.protect(original)
        self.assertNotIn('{name}', protected)
        self.assertNotIn('Markdown', protected)
        restored = protected
        for marker, value in replacements:
            restored = restored.replace(marker, value)
        self.assertEqual(restored, original)
        self.assertEqual(translation.placeholders(restored), ['count', 'name', 'name'])

    def test_dropped_technical_terms_are_rejected_even_without_variables(self):
        original = 'Choose a UTF-8 JSON backup up to 64 MiB.'
        protected, replacements = translation.protect(original)
        self.assertTrue(translation.valid_translation(original, original))
        self.assertFalse(translation.valid_translation(original, 'Choose a backup up to 64.'))
        with self.assertRaisesRegex(ValueError, 'protected'):
            translation.restore_translation(original, protected, replacements,
                                            protected.replace(replacements[0][0], ''))

    def test_effective_targets_follow_actual_reference_packs(self):
        self.assertEqual(translation.reference_target('hbo'), 'he')
        self.assertEqual(translation.reference_target('grc'), 'el')
        self.assertEqual(translation.reference_target('eu'), 'en')
        self.assertEqual(translation.reference_target('enm'), 'en')
        self.assertEqual(translation.reference_target('af'), 'af')


if __name__ == '__main__':
    unittest.main()
