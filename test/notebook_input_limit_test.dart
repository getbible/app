import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/notebook.dart';
import 'package:getbible/presentation/widgets/notebook_input_limit_formatter.dart';

void main() {
  test(
    'title limit counts combining marks as the domain does and preserves accepted text and caret',
    () {
      int rejections = 0;
      final NotebookInputLimitFormatter formatter = NotebookInputLimitFormatter(
        codeUnitCapacity: () => maxNotebookDocumentCodeUnits,
        maxRunes: maxNotebookTitleRunes,
        onLimit: () {
          rejections++;
        },
      );
      const TextEditingValue accepted = TextEditingValue(
        text: 'Saved title',
        selection: TextSelection.collapsed(offset: 3),
      );
      final String tooManyRunes = List<String>.filled(110, 'e\u0301').join();
      expect(tooManyRunes.runes.length, 220);
      expect(
        formatter.formatEditUpdate(
          accepted,
          TextEditingValue(text: tooManyRunes),
        ),
        same(accepted),
      );
      expect(rejections, 1);
      final TextEditingValue valid = TextEditingValue(
        text: List<String>.filled(100, 'e\u0301').join(),
      );
      expect(formatter.formatEditUpdate(accepted, valid), same(valid));
    },
  );
  test(
    'UTF-16 block bounds reject supplementary characters without dropping an existing suffix',
    () {
      int rejections = 0;
      final NotebookInputLimitFormatter formatter = NotebookInputLimitFormatter(
        codeUnitCapacity: () => maxNotebookBlockCodeUnits,
        onLimit: () {
          rejections++;
        },
      );
      const TextEditingValue accepted = TextEditingValue(
        text: 'My unchanged suffix 😀',
        selection: TextSelection.collapsed(offset: 2),
      );
      final String tooLarge = '${List<String>.filled(50000, '😀').join()}x';
      expect(tooLarge.length, 100001);
      expect(
        formatter.formatEditUpdate(accepted, TextEditingValue(text: tooLarge)),
        same(accepted),
      );
      expect(rejections, 1);
    },
  );
  test(
    'aggregate notebook budget constrains a field even when its own block limit permits more text',
    () {
      final DateTime now = DateTime.utc(2026);
      final Notebook notebook = Notebook(
        id: 'budget',
        title: ''.padRight(40, 't'),
        createdAt: now,
        updatedAt: now,
        revision: 1,
        blocks: <NotebookBlock>[
          for (int i = 0; i < 9; i++)
            NotebookBlock(
              id: 'full$i',
              text: ''.padRight(100000, 'x'),
              createdAt: now,
              updatedAt: now,
            ),
          NotebookBlock(
            id: 'target',
            text: ''.padRight(99950, 'y'),
            createdAt: now,
            updatedAt: now,
          ),
        ],
      );
      expect(notebook.textCodeUnits, 999990);
      expect(notebook.blockTextCapacity('target'), 99960);
      expect(notebook.titleTextCapacity, 50);
      int rejections = 0;
      final NotebookInputLimitFormatter formatter = NotebookInputLimitFormatter(
        codeUnitCapacity: () => notebook.blockTextCapacity('target'),
        onLimit: () {
          rejections++;
        },
      );
      final TextEditingValue accepted = TextEditingValue(
        text: notebook.blocks.last.text,
      );
      final TextEditingValue valid = TextEditingValue(
        text: ''.padRight(99960, 'y'),
      );
      expect(formatter.formatEditUpdate(accepted, valid), same(valid));
      expect(
        formatter.formatEditUpdate(
          accepted,
          TextEditingValue(text: ''.padRight(99961, 'y')),
        ),
        same(accepted),
      );
      expect(rejections, 1);
    },
  );
  test('valid native composing text and selection pass through unchanged', () {
    final NotebookInputLimitFormatter formatter = NotebookInputLimitFormatter(
      codeUnitCapacity: () => 100,
      maxRunes: 20,
      onLimit: () => fail('Valid composing input must be retained.'),
    );
    const TextEditingValue composing = TextEditingValue(
      text: 'שָׁלוֹם 😀',
      selection: TextSelection.collapsed(offset: 4),
      composing: TextRange(start: 0, end: 4),
    );
    expect(
      formatter.formatEditUpdate(TextEditingValue.empty, composing),
      same(composing),
    );
  });
}
