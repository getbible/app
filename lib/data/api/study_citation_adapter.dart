import '../../core/json.dart';
import '../../domain/models/study_citation.dart';

/// Dictionary and commentary references share one published coordinate shape.
abstract final class StudyCitationAdapter {
  static StudyCitation parse(Object? value) {
    final JsonMap json = requireJsonMap(value, 'study citation');
    final String reference = requireString(json, 'ref');
    final String osis = requireString(json, 'osis');
    final int book = requireInt(json, 'book');
    final int chapter = requireInt(json, 'chapter');
    final int? verse = json.containsKey('verse')
        ? requireInt(json, 'verse')
        : null;
    final String? text = json.containsKey('text')
        ? requireString(json, 'text')
        : null;
    final List<int> verses = json.containsKey('verses')
        ? requireJsonList(json['verses'], 'citation verses')
              .map((Object? value) {
                if (value is! int || value < 0) {
                  throw const FormatException('Invalid study citation verse.');
                }
                return value;
              })
              .toList(growable: false)
        : const <int>[];
    if (reference.isEmpty ||
        osis.isEmpty ||
        book < 1 ||
        book > 83 ||
        chapter < 0 ||
        (verse != null && verse < 0) ||
        (text != null && text.isEmpty) ||
        (json.containsKey('verses') &&
            (verses.length < 2 ||
                verses.toSet().length != verses.length ||
                (verse != null && !verses.contains(verse))))) {
      throw const FormatException('Invalid published study citation.');
    }
    return StudyCitation(
      reference: reference,
      osis: osis,
      book: book,
      chapter: chapter,
      verse: verse,
      verses: verses,
      text: text,
    );
  }

  static List<StudyCitation> optionalList(JsonMap json) =>
      json.containsKey('references')
      ? List<StudyCitation>.unmodifiable(
          requireJsonList(json['references'], 'study references').map(parse),
        )
      : const <StudyCitation>[];
}
