import '../../core/errors.dart';
import '../../core/json.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/repositories/study_resources_repository.dart';
import 'api_configuration.dart';
import 'api_transport.dart';

/// These adapters follow the native wrapper of each service rather than
/// pretending that its catalogue is an unwrapped array of Bible translations.
abstract final class ServiceEnvelopeAdapters {
  static DictionaryCatalogue dictionaries(Object? value) => _parse(() {
    final JsonMap json = _schema(value, 'getbible-dictionaries-catalog-v1');
    _version(json, 'version');
    _catalogueMetadata(json, <String, String>{
      'metadata_url_template': '{dictionary}/metadata.json',
      'index_url_template': '{dictionary}/index.json',
      'dictionary_url_template': '{dictionary}.json',
      'entry_url_template': '{dictionary}/{entry}.json',
    });
    final List<DictionaryModule> modules =
        requireJsonList(json['dictionaries'], 'dictionaries').map((
          Object? item,
        ) {
          final JsonMap record = requireJsonMap(item, 'dictionary module');
          final Object? strong = record['strong_prefix'];
          if (!record.containsKey('strong_prefix') ||
              (strong != null && strong != 'G' && strong != 'H')) {
            throw const FormatException('Invalid dictionary Strong\'s prefix.');
          }
          return DictionaryModule(
            id: _nonempty(record, 'id'),
            name: _nonempty(record, 'name'),
            language: _nonempty(record, 'language'),
            license: requireString(record, 'license'),
            entryCount: _nonnegative(record, 'entry_count'),
            uniqueKeyCount: _nonnegative(record, 'unique_key_count'),
            strongPrefix: strong as String?,
            bytes: _nonnegative(record, 'bytes'),
            source: _freezeMap(record),
          );
        }).toList();
    if (_nonnegative(json, 'module_count') != modules.length) {
      throw const FormatException(
        'Dictionary module count does not match its catalogue.',
      );
    }
    _uniqueIds(modules.map((DictionaryModule item) => item.id));
    return DictionaryCatalogue(
      modules: List.unmodifiable(modules),
      source: _freezeMap(json),
    );
  });

  static CommentaryCatalogue commentaries(Object? value) => _parse(() {
    final JsonMap json = _schema(value, 'getbible-commentaries-catalog-v1');
    _version(json, 'version');
    _catalogueMetadata(json, <String, String>{
      'metadata_url_template': '{commentary}/metadata.json',
      'books_url_template': '{commentary}/books.json',
      'commentary_url_template': '{commentary}.json',
      'book_url_template': '{commentary}/{book}.json',
      'chapter_url_template': '{commentary}/{book}/{chapter}.json',
    });
    final List<CommentaryModule> modules =
        requireJsonList(json['commentaries'], 'commentaries').map((
          Object? item,
        ) {
          final JsonMap record = requireJsonMap(item, 'commentary module');
          return CommentaryModule(
            id: _nonempty(record, 'id'),
            name: _nonempty(record, 'name'),
            language: _nonempty(record, 'language'),
            license: requireString(record, 'license'),
            bookCount: _nonnegative(record, 'book_count'),
            chapterCount: _nonnegative(record, 'chapter_count'),
            entryCount: _nonnegative(record, 'entry_count'),
            bytes: _nonnegative(record, 'bytes'),
            source: _freezeMap(record),
          );
        }).toList();
    if (_nonnegative(json, 'module_count') != modules.length) {
      throw const FormatException(
        'Commentary module count does not match its catalogue.',
      );
    }
    _uniqueIds(modules.map((CommentaryModule item) => item.id));
    return CommentaryCatalogue(
      modules: List.unmodifiable(modules),
      source: _freezeMap(json),
    );
  });

  static PublicTopicCatalogue publicTopics(Object? value) => _parse(() {
    final JsonMap json = requireJsonMap(value, 'public topic catalogue');
    _version(json, 'schema_version');
    final List<PublicTopicSummary> topics =
        requireJsonList(json['topics'], 'public topics').map((Object? item) {
          final JsonMap record = requireJsonMap(item, 'public topic summary');
          final String id = _nonempty(record, 'id');
          final String color = requireString(record, 'color');
          if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(id) ||
              id.length > 80 ||
              !RegExp(r'^#[0-9a-f]{6}$').hasMatch(color)) {
            throw const FormatException(
              'Invalid public topic identity or color.',
            );
          }
          return PublicTopicSummary(
            id: id,
            name: _nonempty(record, 'name'),
            color: color,
            aliases: _strings(record['aliases'], 'topic aliases'),
            isDefault: _boolean(record, 'default'),
            verseCount: _nonnegative(record, 'verses'),
            source: _freezeMap(record),
          );
        }).toList();
    _uniqueIds(topics.map((PublicTopicSummary item) => item.id));
    return PublicTopicCatalogue(
      topics: List.unmodifiable(topics),
      source: _freezeMap(json),
    );
  });

  static SearchEnvelope search(
    Object? value, {
    String? selectedTranslation,
  }) => _parse(() {
    final JsonMap json = requireJsonMap(value, 'Search v3 envelope');
    final JsonMap query = requireJsonMap(json['query'], 'search query');
    final SearchResultKind kind = switch (requireString(query, 'kind')) {
      'search' => SearchResultKind.search,
      'reference' => SearchResultKind.reference,
      _ => throw const FormatException('Unknown search response kind.'),
    };
    requireString(query, 'text');
    final Object? translationValue = query['translation'];
    final String? advertised = translationValue is String
        ? translationValue
        : _nullableString(
            requireJsonMap(
              translationValue,
              'search translation',
            )['abbreviation'],
            'search translation abbreviation',
          );
    final String? translation = advertised ?? selectedTranslation;
    if (selectedTranslation != null &&
        advertised != null &&
        advertised.toLowerCase() != selectedTranslation.toLowerCase()) {
      throw const FormatException('Search returned a different translation.');
    }
    final JsonMap resultRecords = requireJsonMap(
      json['results'],
      'search results',
    );
    final Map<String, SearchApiChapter> chapters = resultRecords.map((
      String key,
      Object? value,
    ) {
      final JsonMap record = requireJsonMap(value, 'search chapter');
      final int chapter = _nonnegative(record, 'chapter');
      return MapEntry(
        key,
        SearchApiChapter(
          bookNumber: _positive(record, 'book_nr'),
          chapter: chapter,
          verses: List<Verse>.unmodifiable(
            requireJsonList(record['verses'], 'search verses').map(
              (Object? verse) =>
                  Verse.fromJson(verse, fallbackChapter: chapter),
            ),
          ),
          abbreviation: _nullableString(
            record['abbreviation'],
            'chapter abbreviation',
          ),
          bookName: _nullableString(record['book_name'], 'chapter book name'),
          name: _nullableString(record['name'], 'chapter name'),
          source: _freezeMap(record),
        ),
      );
    });
    final List<SearchApiMatch> matches =
        requireJsonList(json['matches'], 'search matches').map((Object? item) {
          final JsonMap record = requireJsonMap(item, 'search match');
          double? score;
          int? occurrences;
          List<String> terms = const [];
          if (kind == SearchResultKind.search) {
            final Object? rawScore = record['score'];
            if (rawScore != null && (rawScore is! num || !rawScore.isFinite)) {
              throw const FormatException('Search match score must be finite.');
            }
            score = rawScore is num ? rawScore.toDouble() : null;
            occurrences = record.containsKey('occurrences')
                ? _nonnegative(record, 'occurrences')
                : null;
            terms = record.containsKey('terms')
                ? _strings(record['terms'], 'search match terms')
                : const [];
          }
          return SearchApiMatch(
            reference: _nonempty(record, 'reference'),
            book: _positive(record, 'book_nr'),
            chapter: _nonnegative(record, 'chapter'),
            verse: _nonnegative(record, 'verse'),
            score: score,
            occurrences: occurrences,
            terms: terms,
            source: _freezeMap(record),
          );
        }).toList();
    final int total = _nonnegative(query, 'total');
    final int returned = _nonnegative(query, 'returned');
    if (returned != matches.length || returned > total) {
      throw const FormatException(
        'Search response counts do not match its results.',
      );
    }
    for (final SearchApiMatch match in matches) {
      final Iterable<SearchApiChapter> corresponding = chapters.values.where(
        (SearchApiChapter chapter) =>
            chapter.bookNumber == match.book &&
            chapter.chapter == match.chapter,
      );
      if (!corresponding.any(
        (SearchApiChapter chapter) =>
            chapter.verses.any((Verse verse) => verse.verse == match.verse),
      )) {
        throw const FormatException(
          'A search match has no corresponding returned verse.',
        );
      }
    }
    return SearchEnvelope(
      kind: kind,
      translation: translation,
      total: total,
      returned: returned,
      engineVersion: requireInt(query, 'engine_version'),
      chapters: Map.unmodifiable(chapters),
      matches: List.unmodifiable(matches),
      offset: kind == SearchResultKind.search && query.containsKey('offset')
          ? _nonnegative(query, 'offset')
          : null,
      limit: kind == SearchResultKind.search && query.containsKey('limit')
          ? _positive(query, 'limit')
          : null,
      hasMore: kind == SearchResultKind.search && query.containsKey('has_more')
          ? _boolean(query, 'has_more')
          : null,
      sourceSha: kind == SearchResultKind.search
          ? _nullableString(query['sha'], 'search SHA')
          : null,
      source: _freezeMap(json),
    );
  });
}

/// Catalogue reads use the shared HTTP policy. They do not download a module,
/// mutate private annotations, or implement the later Study/installation flows.
final class ApiStudyResourcesRepository implements StudyResourcesRepository {
  const ApiStudyResourcesRepository(this.transport);
  final ApiTransport transport;

  @override
  Future<DictionaryCatalogue> getDictionaries({
    RequestCancellation? cancellation,
  }) => _load(
    ApiService.dictionaries,
    '/v1/dictionaries.json',
    ServiceEnvelopeAdapters.dictionaries,
    cancellation,
  );

  @override
  Future<CommentaryCatalogue> getCommentaries({
    RequestCancellation? cancellation,
  }) => _load(
    ApiService.commentaries,
    '/v1/commentaries.json',
    ServiceEnvelopeAdapters.commentaries,
    cancellation,
  );

  @override
  Future<PublicTopicCatalogue> getPublicTopics({
    RequestCancellation? cancellation,
  }) => _load(
    ApiService.bookmarks,
    'topics.json',
    ServiceEnvelopeAdapters.publicTopics,
    cancellation,
  );

  Future<T> _load<T>(
    ApiService service,
    String path,
    T Function(Object?) parse,
    RequestCancellation? cancellation,
  ) async {
    final ApiResponse response = await transport.get(
      service,
      path,
      cancellation: cancellation,
    );
    try {
      return parse(response.json);
    } on ApiFormatException {
      transport.discardResponse(response);
      rethrow;
    }
  }
}

T _parse<T>(T Function() parser) {
  try {
    return parser();
  } on FormatException catch (error) {
    throw ApiFormatException(
      'The GetBible service returned an invalid resource.',
      error,
    );
  }
}

JsonMap _schema(Object? value, String expected) {
  final JsonMap json = requireJsonMap(value, expected);
  if (requireString(json, 'schema') != expected) {
    throw FormatException('Expected $expected.');
  }
  return json;
}

void _version(JsonMap json, String field) {
  if (requireInt(json, field) != 1) {
    throw const FormatException('Unsupported resource version.');
  }
}

void _catalogueMetadata(JsonMap json, Map<String, String> templates) {
  final String timestamp = requireString(json, 'generated_at');
  if (DateTime.tryParse(timestamp) == null) {
    throw const FormatException('Invalid catalogue timestamp.');
  }
  _nonempty(json, 'base_url');
  for (final MapEntry<String, String> entry in templates.entries) {
    if (requireString(json, entry.key) != entry.value) {
      throw FormatException('Unsupported catalogue template ${entry.key}.');
    }
  }
}

String _nonempty(JsonMap json, String field) {
  final String value = requireString(json, field);
  if (value.isEmpty) throw FormatException('$field must not be empty.');
  return value;
}

int _nonnegative(JsonMap json, String field) {
  final int value = requireInt(json, field);
  if (value < 0) throw FormatException('$field must be nonnegative.');
  return value;
}

int _positive(JsonMap json, String field) {
  final int value = _nonnegative(json, field);
  if (value == 0) throw FormatException('$field must be positive.');
  return value;
}

bool _boolean(JsonMap json, String field) {
  final Object? value = json[field];
  if (value is! bool) throw FormatException('$field must be boolean.');
  return value;
}

String? _nullableString(Object? value, String label) {
  if (value == null) return null;
  if (value is! String) {
    throw FormatException('$label must be a string or null.');
  }
  return value;
}

List<String> _strings(Object? value, String label) => List<String>.unmodifiable(
  requireJsonList(value, label).map((Object? item) {
    if (item is! String) throw FormatException('$label must contain strings.');
    return item;
  }),
);

void _uniqueIds(Iterable<String> ids) {
  final Set<String> seen = <String>{};
  for (final String id in ids) {
    if (!seen.add(id)) {
      throw const FormatException('Duplicate catalogue identifier.');
    }
  }
}

JsonMap _freezeMap(JsonMap value) => Map<String, Object?>.unmodifiable(
  value.map((String key, Object? value) => MapEntry(key, _freeze(value))),
);

Object? _freeze(Object? value) {
  if (value is Map) return _freezeMap(requireJsonMap(value, 'source metadata'));
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
