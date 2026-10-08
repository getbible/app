import 'dictionary_folding.dart';
import 'study_citation.dart';

final class DictionaryMetadata {
  DictionaryMetadata({
    required this.id,
    required this.module,
    required this.name,
    required this.language,
    required this.license,
    required this.entryCount,
    required this.uniqueKeyCount,
    required this.strongPrefix,
    required this.bytes,
    required this.source,
    required this.sourceModuleUrl,
    required this.copyright,
    required this.about,
    required this.conversionNote,
    required this.referenceApi,
    required this.referenceVersification,
    required this.referenceLanguage,
    this.copyrightHolder = '',
    this.textSource = '',
    this.distributionNotes = '',
    this.referenceNamingTranslation,
    Iterable<String> referenceTranslations = const <String>[],
    Iterable<String> referenceLibrarian = const <String>[],
    Iterable<String> referenceAliases = const <String>[],
    this.copyrightContact = const DictionaryCopyrightContact(),
    this.version = '',
    this.driver = '',
    this.sourceType = '',
  }) : referenceTranslations = List<String>.unmodifiable(referenceTranslations),
       referenceLibrarian = List<String>.unmodifiable(referenceLibrarian),
       referenceAliases = List<String>.unmodifiable(referenceAliases);
  final String id, module, name, language, license;
  final int entryCount, uniqueKeyCount, bytes;
  final String? strongPrefix;
  final String source, sourceModuleUrl, copyright, about, conversionNote;
  final String referenceApi, referenceVersification, referenceLanguage;
  final String copyrightHolder, textSource, distributionNotes;
  final String? referenceNamingTranslation;
  final List<String> referenceTranslations,
      referenceLibrarian,
      referenceAliases;
  final DictionaryCopyrightContact copyrightContact;
  final String version, driver, sourceType;
}

final class DictionaryCopyrightContact {
  const DictionaryCopyrightContact({
    this.name = '',
    this.email = '',
    this.address = '',
  });
  final String name, email, address;
}

final class DictionaryIndexEntry {
  DictionaryIndexEntry({
    required this.id,
    required this.key,
    required this.search,
    Iterable<String> aliases = const <String>[],
    this.occurrence = 1,
  }) : aliases = List<String>.unmodifiable(aliases);
  final String id, key, search;
  final List<String> aliases;
  final int occurrence;
}

final class DictionaryIndex {
  DictionaryIndex({
    required this.dictionary,
    required this.language,
    required this.name,
    required this.uniqueKeyCount,
    required Iterable<DictionaryIndexEntry> entries,
  }) : entries = List<DictionaryIndexEntry>.unmodifiable(entries) {
    _byId = Map<String, DictionaryIndexEntry>.unmodifiable(
      <String, DictionaryIndexEntry>{
        for (final DictionaryIndexEntry entry in this.entries) entry.id: entry,
      },
    );
    _lookupKeys = List<List<String>>.unmodifiable(
      this.entries.map(
        (DictionaryIndexEntry entry) => List<String>.unmodifiable(
          <String>[
            entry.id,
            entry.key,
            entry.search,
            ...entry.aliases,
          ].map(foldDictionaryKey),
        ),
      ),
    );
  }
  final String dictionary, language, name;
  final int uniqueKeyCount;
  final List<DictionaryIndexEntry> entries;
  late final Map<String, DictionaryIndexEntry> _byId;
  late final List<List<String>> _lookupKeys;
  DictionaryIndexEntry? entryById(String id) => _byId[id];
  List<String> lookupKeysAt(int index) => _lookupKeys[index];
}

final class DictionaryLink {
  const DictionaryLink({required this.id, required this.key});
  final String id, key;
}

final class DictionaryEntry {
  DictionaryEntry({
    required this.dictionary,
    required this.language,
    required this.id,
    required this.key,
    required this.occurrence,
    required this.text,
    required Iterable<String> aliases,
    Iterable<DictionaryLink> seeAlso = const <DictionaryLink>[],
    Iterable<DictionaryLink> backlinks = const <DictionaryLink>[],
    Iterable<StudyCitation> references = const <StudyCitation>[],
  }) : aliases = List<String>.unmodifiable(aliases),
       seeAlso = List<DictionaryLink>.unmodifiable(seeAlso),
       backlinks = List<DictionaryLink>.unmodifiable(backlinks),
       references = List<StudyCitation>.unmodifiable(references);
  final String dictionary, language, id, key, text;
  final int occurrence;
  final List<String> aliases;
  final List<DictionaryLink> seeAlso, backlinks;
  final List<StudyCitation> references;
}

/// Exact source word and lexical values are display data; only the published
/// index decides which values are valid dictionary document identifiers.
final class DictionaryLookup {
  DictionaryLookup({
    required this.sourceWord,
    Iterable<String> strongs = const <String>[],
    Iterable<String> lemmas = const <String>[],
    Iterable<String> morphology = const <String>[],
    Iterable<String> transliterations = const <String>[],
    Iterable<String> candidates = const <String>[],
  }) : strongs = List<String>.unmodifiable(strongs),
       lemmas = List<String>.unmodifiable(lemmas),
       morphology = List<String>.unmodifiable(morphology),
       transliterations = List<String>.unmodifiable(transliterations),
       candidates = List<String>.unmodifiable(candidates);
  final String sourceWord;
  final List<String> strongs, lemmas, morphology, transliterations, candidates;
  String get family {
    if (strongs.isEmpty) return 'surface';
    final List<String> prefixes =
        strongs.map((String value) => value[0]).toSet().toList()..sort();
    return 'strong:${prefixes.join(',')}';
  }
}
