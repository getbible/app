import '../domain/models/bible.dart';
import 'scripture_text.dart';

/// Source commentary is deliberately separate from the selectable verse string.
/// This mirrors the reference reader's annotation rules without moving source
/// offsets or interpreting arbitrary source attributes as executable links.
final class SourceAnnotation {
  const SourceAnnotation({
    required this.id,
    required this.label,
    required this.text,
    this.details = const [],
    this.references = const [],
  });
  final String id;
  final String label;
  final String text;
  final List<String> details;
  final List<String> references;
}

List<SourceAnnotation> verseSourceAnnotations(
  Verse verse, {
  String Function(String)? localizeLabel,
}) {
  String label(String value) => localizeLabel?.call(value) ?? value;
  final mapping = ScriptureTextMap(verse.text);
  final result = <SourceAnnotation>[];
  for (final (index, span) in verse.spans.indexed) {
    final attrs = span.attrs;
    final references = <String>{
      for (final key in ['osisRef', 'ref', 'reference', 'target'])
        if (attrs[key]?.trim().isNotEmpty == true &&
            !RegExp(
              r'^(?:[a-z][a-z0-9+.-]*:|#|//)',
              caseSensitive: false,
            ).hasMatch(attrs[key]!.trim()))
          attrs[key]!.trim(),
    }.toList(growable: false);
    final speaker = attrs['who'];
    final jesus = RegExp(
      r'^#?jesus$',
      caseSensitive: false,
    ).hasMatch(speaker?.trim() ?? '');
    final note = const {
      'note',
      'footnote',
      'reference',
      'ref',
      'crossref',
      'crossreference',
    }.contains(span.tag.toLowerCase());
    if (jesus && !note && references.isEmpty) continue;
    final hasSpeaker = speaker?.trim().isNotEmpty == true && !jesus;
    if (!note &&
        !hasSpeaker &&
        references.isEmpty &&
        mapping.wordRange(span.wordStart, span.wordEnd) != null) {
      continue;
    }
    result.add(
      SourceAnnotation(
        id: 'span-$index',
        label: label(
          hasSpeaker
              ? 'Speaker'
              : references.isNotEmpty
              ? 'Reference'
              : note
              ? 'Source note'
              : 'Source annotation',
        ),
        text: hasSpeaker ? speaker! : span.span,
        details: [
          for (final entry in attrs.entries)
            if (!{
              'who',
              'osisRef',
              'ref',
              'reference',
              'target',
            }.contains(entry.key))
              '${entry.key}: ${entry.value}',
        ],
        references: references,
      ),
    );
  }
  for (final (index, token) in verse.tokens.indexed) {
    if (mapping.tokenRange(token) != null) continue;
    result.add(
      SourceAnnotation(
        id: 'token-$index',
        label: label('Unlocated source word'),
        text: token.token,
        details: [
          for (final (caption, groups) in [
            ('Lemma', token.lemma),
            ('Morphology', token.morph),
            ('Transliteration', token.xlit),
          ])
            if (groups is Map)
              for (final entry in groups.entries)
                '${label(caption)} (${entry.key}): ${(entry.value as List).join(', ')}',
          if (token.attributes['gloss'] case final String gloss)
            '${label('Gloss')}: $gloss',
          if (token.attributes['variant'] == true)
            '${label('Source variant')}${token.attributes['variantType'] is String ? ': ${token.attributes['variantType']}' : ''}',
        ],
      ),
    );
  }
  return List.unmodifiable(result);
}
