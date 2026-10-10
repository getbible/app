import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:getbible/data/api/getbible_api_client.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class ReaderApiFixture {
  ReaderApiFixture({
    this.lastVerse = 3,
    this.firstVerseText = ' First verse. ',
    this.resourceResponse,
  }) {
    api = GetBibleApiClient(client: MockClient(_respond));
  }

  static const int extendedBook = 1000000042;
  final int lastVerse;
  final String firstVerseText;
  final Future<http.Response?> Function(http.Request)? resourceResponse;
  Completer<void>? delayedIndex;
  final Completer<void> indexStarted = Completer<void>();
  final List<String> paths = <String>[];
  late final GetBibleApiClient api;

  Future<http.Response> _respond(http.Request request) async {
    final String path = request.url.path;
    paths.add(path);
    if (request.url.host != 'api.getbible.net' &&
        request.url.host != 'query.getbible.net') {
      final http.Response? resource = await resourceResponse?.call(request);
      if (resource != null) return resource;
    }
    if (request.url.host == 'query.getbible.net') {
      final String reference = request.url.pathSegments.last;
      final RegExpMatch? selection = RegExp(
        r'^Genesis 1:(\d+)$',
      ).firstMatch(reference);
      final int? verse = selection == null
          ? null
          : int.tryParse(selection.group(1)!);
      if (verse == null || verse == 2 || verse < 1 || verse > lastVerse) {
        return http.Response(
          '{"code":"invalid_reference","detail":"The requested fixture verse is unavailable."}',
          404,
          headers: const <String, String>{
            'content-type': 'application/problem+json',
          },
        );
      }
      final Map<String, Object?> chapter =
          jsonDecode(_chapter(1, 1)) as Map<String, Object?>;
      final List<Object?> selected = (chapter['verses']! as List<Object?>)
          .where(
            (Object? item) => (item! as Map<String, Object?>)['verse'] == verse,
          )
          .toList();
      return http.Response(
        jsonEncode(<String, Object?>{
          'tst_1_1': <String, Object?>{
            'book_nr': 1,
            'chapter': 1,
            'book_name': 'Genesis',
            'verses': selected,
            'ref': <String>[reference],
          },
        }),
        200,
        headers: const <String, String>{'content-type': 'application/json'},
      );
    }
    final RegExpMatch? bookDocument = RegExp(
      r'^/v3/tst/(\d+)\.(json|sha)$',
    ).firstMatch(path);
    if (bookDocument != null) {
      final int book = int.parse(bookDocument.group(1)!);
      final int chapter = book == 1 ? 1 : 7;
      final String body = jsonEncode(<String, Object?>{
        'nr': book,
        'name': book == 1 ? 'Genesis' : 'Extended Book',
        'translation': 'Fixture Bible',
        'abbreviation': 'tst',
        'language': 'English',
        'direction': 'LTR',
        'chapters': <Object?>[jsonDecode(_chapter(book, chapter))],
      });
      return http.Response(
        bookDocument.group(2) == 'sha'
            ? sha1.convert(utf8.encode(body)).toString()
            : body,
        200,
        headers: const <String, String>{'cache-control': 'max-age=600'},
      );
    }
    const Map<String, String> headers = <String, String>{
      'content-type': 'application/json',
      'cache-control': 'max-age=600',
    };
    if (path == '/v3/translations.json') {
      return http.Response(
        jsonEncode(<String, Object?>{
          'tst': <String, Object?>{
            'translation': 'Fixture Bible',
            'abbreviation': 'tst',
            'lang': 'en',
            'language': 'English',
            'direction': 'LTR',
            'sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          },
        }),
        200,
        headers: headers,
      );
    }
    if (path == '/v3/tst/books.json') {
      return http.Response(
        jsonEncode(<String, Object?>{
          '1': <String, Object?>{
            'nr': 1,
            'name': 'Genesis',
            'sha': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          },
          '$extendedBook': <String, Object?>{
            'nr': extendedBook,
            'name': 'Extended Book',
            'sha': 'cccccccccccccccccccccccccccccccccccccccc',
          },
        }),
        200,
        headers: headers,
      );
    }
    final RegExpMatch? index = RegExp(
      r'^/v3/tst/(\d+)/chapters.json$',
    ).firstMatch(path);
    if (index != null) {
      final int book = int.parse(index.group(1)!);
      if (book == extendedBook && delayedIndex != null) {
        if (!indexStarted.isCompleted) indexStarted.complete();
        await delayedIndex!.future;
      }
      final int chapter = book == 1 ? 1 : 7;
      final String body = _chapter(book, chapter);
      return http.Response(
        jsonEncode(<String, Object?>{
          '$chapter': <String, Object?>{
            'chapter': chapter,
            'name': 'Fixture $chapter',
            'sha': sha1.convert(utf8.encode(body)).toString(),
          },
        }),
        200,
        headers: headers,
      );
    }
    final RegExpMatch? chapter = RegExp(
      r'^/v3/tst/(\d+)/(\d+)\.(json|sha)$',
    ).firstMatch(path);
    if (chapter != null) {
      final String body = _chapter(
        int.parse(chapter.group(1)!),
        int.parse(chapter.group(2)!),
      );
      return http.Response(
        chapter.group(3) == 'sha'
            ? sha1.convert(utf8.encode(body)).toString()
            : body,
        200,
        headers: headers,
      );
    }
    return http.Response('Missing fixture resource', 404);
  }

  String _chapter(int book, int chapter) => jsonEncode(<String, Object?>{
    'translation': 'Fixture Bible',
    'abbreviation': 'tst',
    'language': 'English',
    'direction': 'LTR',
    'book_nr': book,
    'book_name': book == 1 ? 'Genesis' : 'Extended Book',
    'chapter': chapter,
    'name': 'Fixture $chapter',
    'verses': <Object?>[
      for (int verse = 1; verse <= lastVerse; verse++)
        if (verse != 2)
          <String, Object?>{
            'chapter': chapter,
            'verse': verse,
            'name': 'Fixture $chapter:$verse',
            'text': verse == 1 ? firstVerseText : 'Verse $verse original.',
          },
    ],
  });
}
