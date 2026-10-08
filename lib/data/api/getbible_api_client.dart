import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import '../../core/errors.dart';
import '../../core/json.dart';
import '../../domain/models/bible.dart';
import 'api_configuration.dart';
import 'api_transport.dart';
import 'bible_bulk_parser.dart';

const String getBibleApiRoot = 'https://api.getbible.net/v3';
const String dailyScriptureUrl =
    'https://raw.githubusercontent.com/trueChristian/daily-scripture/refs/heads/master/README.json';

/// Integrity is calculated from received JSON bytes, never a re-serialization.
final class BibleApiDocument<T> {
  BibleApiDocument({
    required this.value,
    required this.response,
    String? digest,
    required this.rawJson,
  }) : digest = digest ?? sha1.convert(response.bytes).toString();
  final T value;
  final ApiResponse response;
  final String digest;
  final String rawJson;
}

final class GetBibleApiClient {
  GetBibleApiClient({
    http.Client? client,
    ApiTransport? transport,
    ApiConfiguration? configuration,
    this.timeout = const Duration(seconds: 15),
  }) : _transport =
           transport ??
           ApiTransport(
             client: client,
             configuration: configuration,
             timeout: timeout,
           ),
       _ownsTransport = transport == null,
       _dailyTransport = ApiTransport(
         client: client,
         timeout: timeout,
         configuration: ApiConfiguration(
           endpoints: <ApiService, ApiServiceEndpoint>{
             ApiService.bible: ApiServiceEndpoint(
               baseUri: Uri.parse(dailyScriptureUrl).replace(path: ''),
               version: 'daily-v1',
             ),
           },
         ),
       );

  final ApiTransport _transport;
  final ApiTransport _dailyTransport;
  final bool _ownsTransport;
  final Duration timeout;
  ApiTransport get transport => _transport;
  String get apiVersion =>
      _transport.configuration.endpoint(ApiService.bible).version;
  String get cacheSourceScope {
    final Uri root = _transport.configuration
        .endpoint(ApiService.bible)
        .baseUri;
    final String normalized = root
        .replace(
          pathSegments: root.pathSegments.where((value) => value.isNotEmpty),
        )
        .toString();
    return normalized == getBibleApiRoot
        ? ''
        : sha256.convert(utf8.encode(normalized)).toString();
  }

  Future<List<Translation>> getTranslations() async =>
      (await getTranslationsDocument()).value;
  Future<BibleApiDocument<List<Translation>>> getTranslationsDocument() async {
    final ApiResponse response = await _transport.get(
      ApiService.bible,
      'translations.json',
      forceRefresh: true,
    );
    return _parseDocument(response, (json) {
      final List<Translation> result = json.values
          .map(Translation.fromJson)
          .toList();
      _requireItems(result, 'translations');
      result.sort((left, right) {
        final int language = left.resolvedLanguage.compareTo(
          right.resolvedLanguage,
        );
        return language != 0
            ? language
            : left.translation.compareTo(right.translation);
      });
      return result;
    });
  }

  Future<List<BibleBook>> getBooks(String translation) async =>
      (await getBooksDocument(translation)).value;
  Future<BibleApiDocument<List<BibleBook>>> getBooksDocument(
    String translation,
  ) async {
    final ApiResponse response = await _transport.get(
      ApiService.bible,
      '${_translation(translation)}/books.json',
      forceRefresh: true,
    );
    return _parseDocument(response, (json) {
      final List<BibleBook> result = sortedNumericValues(
        json,
        BibleBook.fromJson,
      );
      _requireItems(result, 'books');
      return result;
    });
  }

  Future<List<ChapterInfo>> getChapters(String translation, int book) async =>
      (await getChaptersDocument(translation, book)).value;
  Future<BibleApiDocument<List<ChapterInfo>>> getChaptersDocument(
    String translation,
    int book,
  ) async {
    _book(book);
    final ApiResponse response = await _transport.get(
      ApiService.bible,
      '${_translation(translation)}/$book/chapters.json',
      forceRefresh: true,
    );
    // An intro-only source book has no emitted standalone chapter files.
    return _parseDocument(
      response,
      (json) => sortedNumericValues(json, ChapterInfo.fromJson),
    );
  }

  Future<BibleChapter> getChapter(
    String translation,
    int book,
    int chapter,
  ) async => (await getChapterDocument(translation, book, chapter)).value;

  Future<BibleApiDocument<BibleChapter>> getChapterDocument(
    String translation,
    int book,
    int chapter,
  ) async {
    _book(book);
    if (chapter < 1) {
      throw ArgumentError.value(
        chapter,
        'chapter',
        'A standalone Scripture chapter must be positive.',
      );
    }
    final String abbreviation = _translation(translation);
    final ApiResponse response = await _transport.get(
      ApiService.bible,
      '$abbreviation/$book/$chapter.json',
      maxBytes: ApiResponseLimits.chapter,
      forceRefresh: true,
    );
    return _parseDocument(response, (json) {
      final BibleChapter result = BibleChapter.fromJson(json);
      if (result.abbreviation != abbreviation ||
          result.bookNumber != book ||
          result.chapter != chapter) {
        throw const FormatException(
          'The chapter response does not match the requested passage.',
        );
      }
      _requireItems(result.verses, 'verses');
      return result;
    });
  }

  Future<String> getChapterSha(String translation, int book, int chapter) {
    _book(book);
    if (chapter < 1) throw ArgumentError.value(chapter, 'chapter');
    return _getSha('${_translation(translation)}/$book/$chapter.sha');
  }

  Future<String> getBookSha(String translation, int book) {
    _book(book);
    return _getSha('${_translation(translation)}/$book.sha');
  }

  Future<String> getTranslationSha(String translation) =>
      _getSha('${_translation(translation)}.sha');

  Future<BibleApiDocument<WholeTranslationBook>> getBookDocument(
    String translation,
    int book,
  ) async {
    _book(book);
    final String abbreviation = _translation(translation);
    final ApiResponse response = await _transport.get(
      ApiService.bible,
      '$abbreviation/$book.json',
      maxBytes: ApiResponseLimits.bulk,
      forceRefresh: true,
    );
    return _parseBulkDocument(
      response,
      () => BibleBulkParser.book(
        response.bytes,
        abbreviation: abbreviation,
        number: book,
      ),
    );
  }

  Future<WholeTranslation> getWholeTranslation(String translation) async =>
      (await getWholeTranslationDocument(translation)).value;
  Future<BibleApiDocument<WholeTranslation>> getWholeTranslationDocument(
    String translation,
  ) async {
    final String abbreviation = _translation(translation);
    final ApiResponse response = await _transport.get(
      ApiService.bible,
      '$abbreviation.json',
      maxBytes: ApiResponseLimits.bulk,
      forceRefresh: true,
    );
    return _parseBulkDocument(
      response,
      () => BibleBulkParser.translation(
        response.bytes,
        abbreviation: abbreviation,
      ),
    );
  }

  Future<JsonMap> getDailyScripture() => _dailyTransport.getJson(
    ApiService.bible,
    Uri.parse(dailyScriptureUrl).path,
    maxBytes: ApiResponseLimits.metadata,
  );

  Future<BibleApiDocument<T>> _parseBulkDocument<T>(
    ApiResponse response,
    Future<ParsedBibleSource<T>> Function() parse,
  ) async {
    try {
      final ParsedBibleSource<T> source = await parse();
      return BibleApiDocument<T>(
        value: source.value,
        response: response,
        digest: source.digest,
        rawJson: source.rawJson,
      );
    } on ApiFormatException {
      _transport.discardResponse(response);
      rethrow;
    } on FormatException catch (error) {
      _transport.discardResponse(response);
      throw ApiFormatException(
        'The Bible service returned invalid Scripture.',
        error,
      );
    }
  }

  BibleApiDocument<T> _parseDocument<T>(
    ApiResponse response,
    T Function(JsonMap) parse,
  ) {
    try {
      final String raw = response.text;
      return BibleApiDocument<T>(
        value: parse(requireJsonMap(jsonDecode(raw), 'Bible source')),
        response: response,
        rawJson: raw,
      );
    } on ApiFormatException {
      _transport.discardResponse(response);
      rethrow;
    } on FormatException catch (error) {
      _transport.discardResponse(response);
      throw ApiFormatException(
        'The Bible service returned invalid Scripture.',
        error,
      );
    }
  }

  Future<String> _getSha(String path) async {
    final ApiResponse response = await _transport.get(
      ApiService.bible,
      path,
      accept: 'text/plain',
      maxBytes: 128,
      forceRefresh: true,
    );
    try {
      final String hash = response.text.trim().toLowerCase();
      if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(hash)) {
        throw const ApiFormatException(
          'The Bible service returned an invalid SHA-1 hash.',
        );
      }
      return hash;
    } on ApiFormatException {
      _transport.discardResponse(response);
      rethrow;
    }
  }

  String _translation(String value) {
    final String result = value.toLowerCase();
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(result)) {
      throw ArgumentError.value(
        value,
        'translation',
        'Invalid translation identifier.',
      );
    }
    return result;
  }

  void _book(int book) {
    if (book < 1) {
      throw ArgumentError.value(
        book,
        'book',
        'A source book ID must be positive.',
      );
    }
  }

  void _requireItems(List<Object?> values, String resource) {
    if (values.isEmpty) {
      throw ApiFormatException('The Bible service returned no $resource.');
    }
  }

  void close() {
    if (_ownsTransport) _transport.close();
    _dailyTransport.close();
  }
}
