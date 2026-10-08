import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show compute;

import '../../core/json.dart';
import '../../domain/models/bible.dart';

/// A worker returns original text and its byte digest with the parsed content,
/// so activation never re-encodes a large corpus on the reader isolate.
final class ParsedBibleSource<T> {
  const ParsedBibleSource({
    required this.value,
    required this.rawJson,
    required this.digest,
  });
  final T value;
  final String rawJson;
  final String digest;
}

abstract final class BibleBulkParser {
  static Future<ParsedBibleSource<WholeTranslationBook>> book(
    List<int> bytes, {
    required String abbreviation,
    required int number,
  }) => compute(_parseBook, (
    bytes,
    abbreviation,
    number,
  ), debugLabel: 'parseBibleBook');

  static Future<ParsedBibleSource<WholeTranslation>> translation(
    List<int> bytes, {
    required String abbreviation,
  }) => compute(_parseTranslation, (
    bytes,
    abbreviation,
  ), debugLabel: 'parseBibleTranslation');

  static Future<ParsedBibleSource<WholeTranslationBook>> bookText(
    String raw, {
    required String abbreviation,
    required int number,
  }) => compute(_parseBookText, (
    raw,
    abbreviation,
    number,
  ), debugLabel: 'parseSavedBibleBook');
  static Future<ParsedBibleSource<WholeTranslation>> translationText(
    String raw, {
    required String abbreviation,
  }) => compute(_parseTranslationText, (
    raw,
    abbreviation,
  ), debugLabel: 'parseSavedBibleTranslation');
}

ParsedBibleSource<WholeTranslationBook> _parseBook(
  (List<int>, String, int) input,
) => _parseBytes(input.$1, (json) => _bookFromJson(json, input.$2, input.$3));
ParsedBibleSource<WholeTranslation> _parseTranslation(
  (List<int>, String) input,
) => _parseBytes(input.$1, (json) => _translationFromJson(json, input.$2));
ParsedBibleSource<WholeTranslationBook> _parseBookText(
  (String, String, int) input,
) => _parseText(input.$1, (json) => _bookFromJson(json, input.$2, input.$3));
ParsedBibleSource<WholeTranslation> _parseTranslationText(
  (String, String) input,
) => _parseText(input.$1, (json) => _translationFromJson(json, input.$2));

WholeTranslationBook _bookFromJson(
  JsonMap json,
  String abbreviation,
  int number,
) {
  final WholeTranslationBook book = WholeTranslationBook.fromJson(json);
  if (book.number != number ||
      requireString(json, 'abbreviation').toLowerCase() != abbreviation) {
    throw const FormatException(
      'The book response does not match the requested source.',
    );
  }
  _requireReadableBook(book);
  return book;
}

WholeTranslation _translationFromJson(JsonMap json, String abbreviation) {
  final WholeTranslation translation = WholeTranslation.fromJson(json);
  if (translation.abbreviation != abbreviation || translation.books.isEmpty) {
    throw const FormatException(
      'The translation response does not match the requested readable source.',
    );
  }
  for (final book in translation.books) {
    _requireReadableBook(book);
  }
  return translation;
}

void _requireReadableBook(WholeTranslationBook book) {
  if (book.chapters.isEmpty &&
      book.titles.isEmpty &&
      book.introduction.isEmpty) {
    throw const FormatException(
      'The book response contains no readable content.',
    );
  }
  for (final WholeTranslationChapter chapter in book.chapters) {
    if (chapter.chapter < 1 ||
        (chapter.verses.isEmpty && !chapter.isIntroduction)) {
      throw const FormatException(
        'A published nested chapter requires a positive source ID and readable content.',
      );
    }
  }
}

ParsedBibleSource<T> _parseBytes<T>(
  List<int> bytes,
  T Function(JsonMap) parse,
) {
  final String raw = utf8.decode(bytes, allowMalformed: false);
  final JsonMap json = requireJsonMap(jsonDecode(raw), 'Bible source');
  return ParsedBibleSource<T>(
    value: parse(json),
    rawJson: raw,
    digest: sha1.convert(bytes).toString(),
  );
}

ParsedBibleSource<T> _parseText<T>(String raw, T Function(JsonMap) parse) {
  final JsonMap json = requireJsonMap(jsonDecode(raw), 'saved Bible source');
  return ParsedBibleSource<T>(
    value: parse(json),
    rawJson: raw,
    digest: sha1.convert(utf8.encode(raw)).toString(),
  );
}
