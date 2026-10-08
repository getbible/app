import '../../core/json.dart';
import '../../domain/models/dictionary.dart';
import 'study_citation_adapter.dart';

/// Strict native dictionary documents, independent of transport and widgets.
abstract final class DictionaryAdapters {
  static DictionaryMetadata metadata(Object? value, String module) {
    final JsonMap json = _document(value, 'getbible-dictionary-metadata-v1');
    if (_text(json, 'id') != module ||
        requireString(json, 'index_url') != 'index.json' ||
        requireString(json, 'entry_url_template') != '{entry}.json' ||
        requireString(json, 'source') != 'CrossWire SWORD') {
      throw const FormatException('Dictionary metadata identity mismatch.');
    }
    final String? prefix = _prefix(json);
    final JsonMap references = requireJsonMap(
      json['references'],
      'reference provenance',
    );
    if (requireString(references, 'api') != 'getbible-v2') {
      throw const FormatException(
        'Unsupported dictionary citation provenance.',
      );
    }
    for (final String key in <String>['translations', 'librarian', 'aliases']) {
      _strings(references[key], 'reference $key');
    }
    final Object? names = references['names'];
    if (!references.containsKey('names') ||
        (names != null && names is! String)) {
      throw const FormatException('Invalid reference naming translation.');
    }
    final JsonMap contact = requireJsonMap(
      json['copyright_contact'],
      'copyright contact',
    );
    for (final String key in <String>['name', 'email', 'address']) {
      requireString(contact, key);
    }
    for (final String key in <String>[
      'version',
      'driver',
      'source_type',
      'text_source',
      'copyright_holder',
      'distribution_notes',
    ]) {
      requireString(json, key);
    }
    final String language = _language(json);
    return DictionaryMetadata(
      id: module,
      module: _text(json, 'module'),
      name: _text(json, 'name'),
      language: language,
      license: requireString(json, 'license'),
      entryCount: _number(json, 'entry_count'),
      uniqueKeyCount: _number(json, 'unique_key_count'),
      strongPrefix: prefix,
      bytes: _number(json, 'bytes'),
      source: requireString(json, 'source'),
      sourceModuleUrl: _text(json, 'source_module_url'),
      copyright: requireString(json, 'copyright'),
      about: requireString(json, 'about'),
      conversionNote: _text(json, 'conversion_note'),
      referenceApi: requireString(references, 'api'),
      referenceVersification: requireString(references, 'versification'),
      referenceLanguage: requireString(references, 'language'),
      version: requireString(json, 'version'),
      driver: requireString(json, 'driver'),
      sourceType: requireString(json, 'source_type'),
      copyrightHolder: requireString(json, 'copyright_holder'),
      textSource: requireString(json, 'text_source'),
      distributionNotes: requireString(json, 'distribution_notes'),
      referenceNamingTranslation: names as String?,
      referenceTranslations: List<String>.unmodifiable(
        _strings(references['translations'], 'reference translations'),
      ),
      referenceLibrarian: List<String>.unmodifiable(
        _strings(references['librarian'], 'reference librarian'),
      ),
      referenceAliases: List<String>.unmodifiable(
        _strings(references['aliases'], 'reference aliases'),
      ),
      copyrightContact: DictionaryCopyrightContact(
        name: requireString(contact, 'name'),
        email: requireString(contact, 'email'),
        address: requireString(contact, 'address'),
      ),
    );
  }

  static DictionaryIndex index(Object? value, String module) {
    final JsonMap json = _document(value, 'getbible-dictionary-index-v1');
    if (_text(json, 'dictionary') != module ||
        requireString(json, 'entry_url_template') != '{entry}.json') {
      throw const FormatException('Dictionary index identity mismatch.');
    }
    final List<DictionaryIndexEntry> entries =
        requireJsonList(json['entries'], 'dictionary index')
            .map((Object? value) {
              final JsonMap item = requireJsonMap(
                value,
                'dictionary index entry',
              );
              final int occurrence = item.containsKey('occurrence')
                  ? _number(item, 'occurrence', minimum: 2)
                  : 1;
              return DictionaryIndexEntry(
                id: _text(item, 'id'),
                key: _text(item, 'key'),
                search: _text(item, 'search'),
                occurrence: occurrence,
                aliases: item.containsKey('aliases')
                    ? _strings(item['aliases'], 'index aliases', minimum: 1)
                    : const <String>[],
              );
            })
            .toList(growable: false);
    final int count = _number(json, 'entry_count');
    final int unique = _number(json, 'unique_key_count');
    if (count != entries.length ||
        unique > count ||
        entries.map((DictionaryIndexEntry item) => item.id).toSet().length !=
            count) {
      throw const FormatException(
        'Dictionary index has inconsistent counts or identities.',
      );
    }
    return DictionaryIndex(
      dictionary: module,
      language: _language(json),
      name: _text(json, 'name'),
      uniqueKeyCount: unique,
      entries: entries,
    );
  }

  static DictionaryEntry entry(Object? value, String module, String id) {
    final JsonMap json = _document(value, 'getbible-dictionary-entry-v1');
    if (_text(json, 'dictionary') != module || _text(json, 'id') != id) {
      throw const FormatException('Dictionary entry identity mismatch.');
    }
    return DictionaryEntry(
      dictionary: module,
      language: _language(json),
      id: id,
      key: _text(json, 'key'),
      occurrence: _number(json, 'occurrence', minimum: 1),
      text: requireString(json, 'text'),
      aliases: _strings(json['aliases'], 'entry aliases', minimum: 1),
      seeAlso: _links(json, 'see_also'),
      backlinks: _links(json, 'backlinks'),
      references: StudyCitationAdapter.optionalList(json),
    );
  }

  static List<DictionaryLink> _links(JsonMap json, String key) =>
      json.containsKey(key)
      ? requireJsonList(json[key], key)
            .map((Object? value) {
              final JsonMap link = requireJsonMap(value, 'dictionary link');
              return DictionaryLink(
                id: _text(link, 'id'),
                key: _text(link, 'key'),
              );
            })
            .toList(growable: false)
      : const <DictionaryLink>[];
}

JsonMap _document(Object? value, String schema) {
  final JsonMap json = requireJsonMap(value, schema);
  if (requireString(json, 'schema') != schema) {
    throw FormatException('Expected $schema.');
  }
  return json;
}

String _text(JsonMap json, String key) {
  final String text = requireString(json, key);
  if (text.isEmpty) throw FormatException('$key must not be empty.');
  return text;
}

String _language(JsonMap json) {
  final String language = _text(json, 'language');
  if (language.length < 2) {
    throw const FormatException('Invalid dictionary language.');
  }
  return language;
}

int _number(JsonMap json, String key, {int minimum = 0}) {
  final int number = requireInt(json, key);
  if (number < minimum) throw FormatException('$key is below $minimum.');
  return number;
}

String? _prefix(JsonMap json) {
  final Object? value = json['strong_prefix'];
  if (!json.containsKey('strong_prefix') ||
      (value != null && value != 'G' && value != 'H')) {
    throw const FormatException('Invalid dictionary Strong prefix.');
  }
  return value as String?;
}

List<String> _strings(Object? value, String label, {int minimum = 0}) {
  final List<String> strings = requireJsonList(value, label)
      .map((Object? value) {
        if (value is! String) {
          throw FormatException('$label must contain strings.');
        }
        return value;
      })
      .toList(growable: false);
  if (strings.length < minimum) throw FormatException('$label is empty.');
  return strings;
}
