import '../core/request_cancellation.dart';
import '../domain/models/bible.dart';
import '../domain/models/dictionary.dart';
import '../domain/models/dictionary_folding.dart';
import '../domain/models/study_context.dart';
import '../services/scripture_text.dart';

/// Native UTF-16 selections map to published token word ranges before lookup.
/// Never equates a token array index with a Scripture character offset.
abstract final class DictionaryLookupBuilder {
  static DictionaryLookup fromContext(StudyContext context) {
    final String source = context.selectedText ?? '';
    final Set<String> strongs = <String>{};
    final Set<String> lemmas = <String>{};
    final Set<String> morphology = <String>{};
    final Set<String> transliterations = <String>{};
    final Verse? verse = context.verse;
    if (verse != null && context.selectedText != null) {
      final ScriptureTextRange selection = ScriptureTextRange(
        context.selectionStart!,
        context.selectionEnd!,
      );
      final ScriptureTextMap map = ScriptureTextMap(verse.text);
      for (final ScriptureToken token in verse.tokens) {
        if (!(map.tokenRange(token)?.overlaps(selection) ?? false)) continue;
        for (final String lemma in _values(token.lemma)) {
          if (RegExp(r'^[GH][0-9]+$').hasMatch(lemma)) {
            strongs.add(lemma);
          } else {
            lemmas.add(lemma);
          }
        }
        morphology.addAll(_values(token.morph));
        transliterations.addAll(_values(token.xlit));
      }
    }
    final Set<String> candidates = <String>{
      ...strongs,
      ...lemmas,
      ...transliterations,
    };
    if (source.isNotEmpty) {
      candidates.add(source);
      final String punctuationTrimmed = source.replaceAll(
        RegExp(r'^[^\p{L}\p{N}\p{M}]+|[^\p{L}\p{N}\p{M}]+$', unicode: true),
        '',
      );
      if (punctuationTrimmed.isNotEmpty) candidates.add(punctuationTrimmed);
    }
    return DictionaryLookup(
      sourceWord: source,
      strongs: strongs,
      lemmas: lemmas,
      morphology: morphology,
      transliterations: transliterations,
      candidates: candidates,
    );
  }

  static Iterable<String> _values(Object? value) sync* {
    // ScriptureToken validates lexical group structure on ingestion.
    if (value is! Map<String, Object?>) return;
    for (final Object? group in value.values) {
      if (group is! List<Object?>) continue;
      for (final Object? item in group) {
        if (item is String && item.isNotEmpty) yield item;
      }
    }
  }
}

/// Searches published keys and aliases, retaining every distinct definition.
/// Strong identifiers are exact candidates; an advertised prefix is never an
/// instruction to synthesize an entry URL.
abstract final class DictionaryIndexLookup {
  static List<DictionaryIndexEntry> exact(
    DictionaryIndex index,
    Iterable<String> candidates,
  ) {
    final Set<String> terms = candidates
        .map(foldDictionaryKey)
        .where((String item) => item.isNotEmpty)
        .toSet();
    return List<DictionaryIndexEntry>.unmodifiable(<DictionaryIndexEntry>[
      for (int position = 0; position < index.entries.length; position++)
        if (index.lookupKeysAt(position).any(terms.contains))
          index.entries[position],
    ]);
  }

  static Future<List<DictionaryIndexEntry>> exactCooperatively(
    DictionaryIndex index,
    Iterable<String> candidates,
    RequestCancellation cancellation,
  ) async {
    final terms = candidates
        .map(foldDictionaryKey)
        .where((term) => term.isNotEmpty)
        .toSet();
    final matches = <DictionaryIndexEntry>[];
    for (var position = 0; position < index.entries.length; position++) {
      if (position % 1024 == 0) {
        cancellation.throwIfCancelled();
        if (position > 0) await Future<void>.delayed(Duration.zero);
      }
      if (index.lookupKeysAt(position).any(terms.contains)) {
        matches.add(index.entries[position]);
      }
    }
    cancellation.throwIfCancelled();
    return List.unmodifiable(matches);
  }

  static List<DictionaryIndexEntry> filter(
    DictionaryIndex index,
    String query,
  ) {
    final String term = foldDictionaryKey(query);
    if (term.isEmpty) return const <DictionaryIndexEntry>[];
    final List<DictionaryIndexEntry> exact = <DictionaryIndexEntry>[];
    final List<DictionaryIndexEntry> prefix = <DictionaryIndexEntry>[];
    for (int position = 0; position < index.entries.length; position++) {
      final DictionaryIndexEntry entry = index.entries[position];
      final List<String> keys = index.lookupKeysAt(position);
      if (keys.contains(term)) {
        exact.add(entry);
      } else if (keys.any((String key) => key.startsWith(term))) {
        prefix.add(entry);
      }
    }
    return List<DictionaryIndexEntry>.unmodifiable(<DictionaryIndexEntry>[
      ...exact,
      ...prefix,
    ]);
  }

  /// Browser-friendly cooperative filtering of a large published index.
  /// Precomputed keys avoid re-normalizing every word on every keystroke.
  static Future<List<DictionaryIndexEntry>> filterCooperatively(
    DictionaryIndex index,
    String query,
    RequestCancellation cancellation, {
    int? limit,
  }) async {
    final String term = foldDictionaryKey(query);
    if (term.isEmpty) return const <DictionaryIndexEntry>[];
    final List<DictionaryIndexEntry> exact = <DictionaryIndexEntry>[];
    final List<DictionaryIndexEntry> prefix = <DictionaryIndexEntry>[];
    for (int position = 0; position < index.entries.length; position++) {
      if (position % 1024 == 0) {
        cancellation.throwIfCancelled();
        if (position > 0) await Future<void>.delayed(Duration.zero);
      }
      final List<String> keys = index.lookupKeysAt(position);
      if (keys.contains(term)) {
        exact.add(index.entries[position]);
      } else if (keys.any((String key) => key.startsWith(term))) {
        if (limit == null || prefix.length < limit) {
          prefix.add(index.entries[position]);
        }
      }
    }
    cancellation.throwIfCancelled();
    final results = <DictionaryIndexEntry>[...exact, ...prefix];
    return List<DictionaryIndexEntry>.unmodifiable(
      limit == null ? results : results.take(limit),
    );
  }
}
