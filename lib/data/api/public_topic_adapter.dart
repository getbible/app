import '../../core/errors.dart';
import '../../core/json.dart';
import '../../domain/models/public_topic.dart';
import '../../domain/models/service_envelopes.dart';
import 'service_envelope_adapters.dart';

/// Static Bookmarks v1 documents deliberately have different `verses` shapes.
abstract final class PublicTopicAdapter {
  static PublicTopicDiscovery discovery(Object? value) => _parse(() {
    final JsonMap json = _document(value);
    final JsonMap counts = requireJsonMap(json['counts'], 'topic counts');
    final String checksum = requireString(json, 'checksum');
    if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(checksum)) {
      throw const FormatException('Invalid public-topic checksum.');
    }
    final Map<String, String> resources =
        requireJsonMap(json['resources'], 'topic resource paths').map((
          String key,
          Object? value,
        ) {
          if (value is! String || value.isEmpty) {
            throw const FormatException('Invalid topic resource path.');
          }
          final Uri path = Uri.parse(value);
          if (path.hasScheme ||
              path.hasAuthority ||
              path.hasQuery ||
              path.hasFragment ||
              value.startsWith('/') ||
              path.pathSegments.any(
                (String item) => item == '..' || item == '.',
              )) {
            throw const FormatException(
              'Topic paths must remain in their service root.',
            );
          }
          return MapEntry(key, value);
        });
    final List<String> locales = _strings(json['locales'], 'topic locales');
    for (final String locale in locales) {
      validateLocale(locale);
    }
    final int localeCount = _integer(counts, 'locales', 0);
    if (locales.toSet().length != locales.length ||
        localeCount != locales.length ||
        !locales.contains('en')) {
      throw const FormatException('Invalid topic locale discovery.');
    }
    return PublicTopicDiscovery(
      catalogVersion: _integer(json, 'catalog_version', 1),
      checksum: checksum,
      topicCount: _integer(counts, 'topics', 0),
      associationCount: _integer(counts, 'verses', 0),
      localeCount: localeCount,
      resources: resources,
      locales: locales,
    );
  });

  static PublicTopicCatalogue catalogue(Object? value) => _parse(() {
    final PublicTopicCatalogue result = ServiceEnvelopeAdapters.publicTopics(
      value,
    );
    for (final PublicTopicSummary item in result.topics) {
      _metadata(item.id, item.name, item.color, item.aliases);
    }
    return result;
  });

  static PublicTopic topic(
    Object? value, {
    required String expectedId,
  }) => _parse(() {
    final JsonMap json = _document(value);
    final String id = requireString(json, 'id');
    final String name = requireString(json, 'name');
    final String color = requireString(json, 'color');
    final List<String> aliases = _strings(json['aliases'], 'topic aliases');
    _metadata(id, name, color, aliases);
    if (id != expectedId) {
      throw const FormatException('The topic returned a different id.');
    }
    final Object? isDefault = json['default'];
    if (isDefault is! bool) {
      throw const FormatException('Invalid topic default flag.');
    }
    final Map<String, String> names = _nameMap(json['names'], locales: true);
    if (!names.containsKey('en')) {
      throw const FormatException('A topic requires its English name.');
    }
    final List<Object?> rawCoordinates = requireJsonList(
      json['verses'],
      'topic coordinates',
    );
    if (rawCoordinates.length > 100000) {
      throw const FormatException('Too many topic associations.');
    }
    final List<PublicTopicCoordinate> coordinates = <PublicTopicCoordinate>[];
    for (final Object? raw in rawCoordinates) {
      final List<Object?> triple = requireJsonList(raw, 'topic coordinate');
      if (triple.length != 3 || triple.any((Object? item) => item is! int)) {
        throw const FormatException(
          'A topic coordinate requires three integer fields.',
        );
      }
      final PublicTopicCoordinate coordinate = PublicTopicCoordinate(
        triple[0]! as int,
        triple[1]! as int,
        triple[2]! as int,
      );
      if (coordinate.book < 1 ||
          coordinate.book > 66 ||
          coordinate.chapter < 1 ||
          coordinate.chapter > 150 ||
          coordinate.verse < 1 ||
          coordinate.verse > 2000 ||
          (coordinates.isNotEmpty &&
              coordinates.last.compareTo(coordinate) >= 0)) {
        throw const FormatException(
          'Topic coordinates must be valid, sorted and unique.',
        );
      }
      coordinates.add(coordinate);
    }
    return PublicTopic(
      id: id,
      name: name,
      color: color,
      aliases: aliases,
      isDefault: isDefault,
      names: names,
      coordinates: coordinates,
    );
  });

  static PublicTopicAssociations chapter(
    Object? value, {
    required int book,
    required int chapter,
  }) => _parse(() {
    final JsonMap json = _document(value);
    if (_integer(json, 'book', 1, 66) != book ||
        _integer(json, 'chapter', 1, 150) != chapter) {
      throw const FormatException(
        'The reverse lookup returned a different chapter.',
      );
    }
    final Map<int, List<String>> verses = <int, List<String>>{};
    for (final MapEntry<String, Object?> entry in requireJsonMap(
      json['verses'],
      'reverse topic verses',
    ).entries) {
      final int? verse = int.tryParse(entry.key);
      if (verse == null ||
          verse < 1 ||
          verse > 2000 ||
          verse.toString() != entry.key) {
        throw const FormatException('Invalid reverse lookup verse identity.');
      }
      final List<String> ids = _strings(entry.value, 'reverse topic ids');
      if (ids.isEmpty || ids.toSet().length != ids.length) {
        throw const FormatException('Invalid reverse topic associations.');
      }
      for (final String id in ids) {
        validateId(id);
      }
      verses[verse] = ids;
    }
    return PublicTopicAssociations(
      book: book,
      chapter: chapter,
      verses: verses,
    );
  });

  static List<PublicTopicLocale> locales(Object? value) => _parse(() {
    final JsonMap json = _document(value);
    final Set<String> seen = <String>{};
    final List<PublicTopicLocale> locales = <PublicTopicLocale>[];
    for (final Object? raw in requireJsonList(
      json['locales'],
      'topic locales',
    )) {
      final JsonMap record = requireJsonMap(raw, 'topic locale');
      final String code = requireString(record, 'code');
      validateLocale(code);
      final Object? name = record['name'];
      if (!record.containsKey('name') ||
          (name != null && (name is! String || name.length > 80)) ||
          !seen.add(code)) {
        throw const FormatException('Invalid topic locale metadata.');
      }
      locales.add(
        PublicTopicLocale(
          code: code,
          name: name as String?,
          topicCount: _integer(record, 'topics', 0),
        ),
      );
    }
    if (!seen.contains('en')) {
      throw const FormatException('English topic names are required.');
    }
    return List<PublicTopicLocale>.unmodifiable(locales);
  });

  static PublicTopicNames names(Object? value, {required String locale}) =>
      _parse(() {
        final JsonMap json = _document(value);
        if (requireString(json, 'locale') != locale) {
          throw const FormatException(
            'The locale returned a different language.',
          );
        }
        if (json.containsKey('name')) _text(requireString(json, 'name'), 80);
        return PublicTopicNames(
          locale: locale,
          names: _nameMap(json['topics'], locales: false),
        );
      });

  static void validateId(String id) {
    if (id.length > 80 || !RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(id)) {
      throw const FormatException('Use an exact published topic id.');
    }
  }

  static void validateLocale(String locale) {
    if (locale.length > 16 ||
        !RegExp(r'^[a-z]{2,3}(?:-[a-z0-9]{2,8})*$').hasMatch(locale)) {
      throw const FormatException('Use a published lowercase topic locale.');
    }
  }
}

T _parse<T>(T Function() operation) {
  try {
    return operation();
  } on FormatException catch (error) {
    throw ApiFormatException(
      'The public-topic service returned invalid data.',
      error,
    );
  }
}

JsonMap _document(Object? value) {
  final JsonMap json = requireJsonMap(value, 'public-topic document');
  if (requireInt(json, 'schema_version') != 1) {
    throw const FormatException('Unsupported public-topic format.');
  }
  return json;
}

int _integer(JsonMap json, String key, int minimum, [int? maximum]) {
  final int value = requireInt(json, key);
  if (value < minimum || (maximum != null && value > maximum)) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

List<String> _strings(Object? value, String label) =>
    requireJsonList(value, label)
        .map((Object? item) {
          if (item is! String) {
            throw FormatException('$label requires text values.');
          }
          return item;
        })
        .toList(growable: false);

Map<String, String> _nameMap(Object? value, {required bool locales}) =>
    requireJsonMap(value, 'translated topic names').map((
      String key,
      Object? value,
    ) {
      if (locales) {
        PublicTopicAdapter.validateLocale(key);
      } else {
        PublicTopicAdapter.validateId(key);
      }
      if (value is! String) {
        throw const FormatException('A translated topic name requires text.');
      }
      _text(value, 120);
      return MapEntry(key, value);
    });

void _text(String value, int maxLength) {
  if (value.isEmpty || value.runes.length > maxLength) {
    throw const FormatException('Invalid topic display text.');
  }
}

void _metadata(String id, String name, String color, List<String> aliases) {
  PublicTopicAdapter.validateId(id);
  _text(name, 80);
  if (!RegExp(r'^#[0-9a-f]{6}$').hasMatch(color) ||
      aliases.length > 20 ||
      aliases.toSet().length != aliases.length) {
    throw const FormatException('Invalid topic metadata.');
  }
  for (final String alias in aliases) {
    _text(alias, 80);
  }
}
