import '../core/errors.dart';
import '../core/request_cancellation.dart';
import '../domain/models/dictionary.dart';
import '../domain/models/service_envelopes.dart';
import '../domain/repositories/dictionary_repository.dart';
import 'dictionary_lookup.dart';

/// A resource is a choice only after at least one exact published entry has a
/// nonempty definition. Index suggestions do not imply a definition exists.
final class ConfirmedDictionary {
  ConfirmedDictionary(this.module, Iterable<DictionaryEntry> definitions)
    : definitions = List.unmodifiable(definitions);
  final DictionaryModule module;
  final List<DictionaryEntry> definitions;
}

final class DictionarySuggestion {
  const DictionarySuggestion(this.module, this.entry);
  final DictionaryModule module;
  final DictionaryIndexEntry entry;
}

final class DictionaryDiscoveryResult {
  DictionaryDiscoveryResult({
    required Iterable<ConfirmedDictionary> matches,
    required Iterable<String> unavailable,
    required Iterable<DictionarySuggestion> suggestions,
    required this.complete,
    this.limitReached = false,
  }) : matches = List.unmodifiable(matches),
       unavailable = List.unmodifiable(unavailable),
       suggestions = List.unmodifiable(suggestions);
  final List<ConfirmedDictionary> matches;
  final List<String> unavailable;
  final List<DictionarySuggestion> suggestions;
  final bool complete;
  final bool limitReached;
}

/// Bounded cross-resource discovery. Only public indexes and exact indexed
/// entries are requested, never complete modules or guessed Strong's URLs.
/// Each call retains at most 400,000 index records and 2M definition characters;
/// four workers share index/definition work. Cancellation is checked between
/// requests and cooperative index slices, including repositories that respond
/// late. Failed resources never suppress confirmed choices from other sources.
final class DictionaryDiscovery {
  DictionaryDiscovery(this.repository);
  final DictionaryRepository repository;
  final Map<String, DictionaryIndex> _indexes = {};
  Object? _publication;
  DateTime? _indexedAt;
  void clearIndexes() {
    _indexes.clear();
    _publication = null;
    _indexedAt = null;
  }

  static const concurrency = 4;
  static const maxIndexEntries = 400000;
  static const maxDefinitions = 256;
  static const maxDefinitionCharacters = 2000000;
  static const maxSuggestions = 20;

  Future<DictionaryDiscoveryResult> lookup({
    required List<DictionaryModule> modules,
    Object? publication,
    required List<String> candidates,
    required String query,
    required RequestCancellation cancellation,
    void Function(DictionaryDiscoveryResult)? onProgress,
  }) async {
    // Discovery reuses normalized indexes while this catalogue snapshot is
    // current. Public cache expiry and installation changes invalidate it.
    if (_publication != publication ||
        _indexedAt == null ||
        DateTime.now().difference(_indexedAt!) > const Duration(minutes: 15)) {
      clearIndexes();
      _publication = publication;
      _indexedAt = DateTime.now();
    }
    final publicationAtStart = _publication;
    final matches = <String, ConfirmedDictionary>{};
    final unavailable = <String>{};
    final suggestions = <DictionarySuggestion>[];
    var position = 0;
    var reservedEntries = 0;
    var definitions = 0;
    var characters = 0;
    var limitReached = false;
    DictionaryDiscoveryResult snapshot(bool complete) =>
        DictionaryDiscoveryResult(
          matches: modules.map((module) => matches[module.id]).nonNulls,
          unavailable: modules
              .where((module) => unavailable.contains(module.id))
              .map((module) => module.id),
          suggestions: matches.isEmpty ? suggestions : const [],
          complete: complete,
          limitReached: limitReached,
        );

    Future<void> worker() async {
      while (position < modules.length) {
        cancellation.throwIfCancelled();
        final module = modules[position++];
        if (module.entryCount == 0) continue;
        if (reservedEntries + module.entryCount > maxIndexEntries) {
          limitReached = true;
          unavailable.add(module.id);
          onProgress?.call(snapshot(false));
          continue;
        }
        // Reserve before awaiting so parallel workers cannot exceed the budget.
        reservedEntries += module.entryCount;
        try {
          final DictionaryIndex index =
              _indexes[module.id] ??
              await cancellation.bind<DictionaryIndex>(
                repository.index(module.id, cancellation: cancellation),
              );
          if (index.dictionary != module.id ||
              index.entries.length != module.entryCount ||
              index.uniqueKeyCount != module.uniqueKeyCount) {
            throw const ApiFormatException(
              'The dictionary catalogue and index are inconsistent.',
            );
          }
          cancellation.throwIfCancelled();
          if (_publication == publicationAtStart) {
            // The same 400k admission budget applies to the retained cache.
            while (_indexes.isNotEmpty &&
                !_indexes.containsKey(module.id) &&
                _indexes.values.fold<int>(
                          0,
                          (total, value) => total + value.entries.length,
                        ) +
                        index.entries.length >
                    maxIndexEntries) {
              _indexes.remove(_indexes.keys.first);
            }
            _indexes[module.id] = index;
          }
          final exact = await DictionaryIndexLookup.exactCooperatively(
            index,
            candidates,
            cancellation,
          );
          if (exact.isEmpty && suggestions.length < maxSuggestions) {
            final related = await DictionaryIndexLookup.filterCooperatively(
              index,
              query,
              cancellation,
              limit: maxSuggestions - suggestions.length,
            );
            suggestions.addAll(
              related
                  .take(maxSuggestions - suggestions.length)
                  .map((entry) => DictionarySuggestion(module, entry)),
            );
          }
          final found = <DictionaryEntry>[];
          for (final candidate in exact) {
            cancellation.throwIfCancelled();
            if (definitions >= maxDefinitions) {
              limitReached = true;
              unavailable.add(module.id);
              break;
            }
            definitions++;
            try {
              final entry = await cancellation.bind(
                repository.entry(
                  module.id,
                  candidate.id,
                  cancellation: cancellation,
                ),
              );
              if (entry.dictionary != module.id || entry.id != candidate.id) {
                throw const ApiFormatException(
                  'The dictionary entry identity changed.',
                );
              }
              if (entry.text.trim().isEmpty) continue;
              if (characters + entry.text.length > maxDefinitionCharacters) {
                limitReached = true;
                unavailable.add(module.id);
                continue;
              }
              characters += entry.text.length;
              found.add(entry);
            } on HttpStatusException catch (error) {
              if (error.statusCode != 404) unavailable.add(module.id);
            } on RequestCancelledException {
              rethrow;
            } catch (_) {
              unavailable.add(module.id);
            }
          }
          if (found.isNotEmpty) {
            matches[module.id] = ConfirmedDictionary(module, found);
          }
        } on RequestCancelledException {
          rethrow;
        } catch (_) {
          unavailable.add(module.id);
        }
        cancellation.throwIfCancelled();
        onProgress?.call(snapshot(false));
      }
    }

    await Future.wait(
      List.generate(
        modules.length < concurrency ? modules.length : concurrency,
        (_) => worker(),
      ),
    );
    cancellation.throwIfCancelled();
    return snapshot(true);
  }
}
