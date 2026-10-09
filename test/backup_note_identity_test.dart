import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/domain/models/annotations.dart';
import 'package:getbible_live/domain/models/backup.dart';
import 'package:getbible_live/domain/models/passage.dart';

void main() {
  test('earlier imported coordinate cannot take a local note identity', () {
    final local = _note('same', 2, 'Local text', 20);
    final imported = _note('same', 1, 'Imported text', 30);
    final merged = mergeNotes([local], [imported]);
    expect(
      merged.singleWhere((note) => note.passage.book == 2).toJson(),
      local.toJson(),
    );
    expect(merged.first.id, 'same-imported-1');
    expect(merged.first.text, imported.text);
    expect(merged.first.createdAt, imported.createdAt);
    expect(merged.first.updatedAt, imported.updatedAt);
  });

  test(
    'generated suffix cannot take a later local or incoming original ID',
    () {
      final local = [
        _note('same', 2, 'Local', 20),
        _note('same-imported-1', 4, 'Other local', 20),
      ];
      final imported = [
        _note('same', 1, 'Import', 30),
        _note('same-imported-2', 3, 'Other import', 30),
      ];
      final merged = mergeNotes(local, imported);
      expect(merged.map((note) => note.id), [
        'same-imported-3',
        'same',
        'same-imported-2',
        'same-imported-1',
      ]);
      for (final note in local) {
        expect(
          merged
              .singleWhere((item) => item.canonicalKey == note.canonicalKey)
              .toJson(),
          note.toJson(),
        );
      }
      expect(
        mergeNotes(merged, imported).map((note) => note.toJson()),
        merged.map((note) => note.toJson()),
      );
    },
  );

  test(
    'newer canonical note still wins and equal timestamps retain local content',
    () {
      final local = _note('local', 1, 'Original', 20);
      final equal = _note('incoming', 1, 'Same time', 20);
      expect(mergeNotes([local], [equal]).single.toJson(), local.toJson());
      final newer = _note('newer', 1, 'New content', 30);
      expect(mergeNotes([local], [newer]).single.toJson(), newer.toJson());
    },
  );
}

VerseNote _note(String id, int book, String text, int updated) => VerseNote(
  id: id,
  passage: Passage(translation: 'kjv', book: book, chapter: 1),
  verse: 1,
  reference: 'Book $book 1:1',
  text: text,
  createdAt: DateTime.fromMillisecondsSinceEpoch(10, isUtc: true),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(updated, isUtc: true),
);
