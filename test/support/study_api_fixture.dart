import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'reader_api_fixture.dart';

/// Uses the same contract-validated resources as the focused feature tests.
/// The complete reader and every Study repository share one HTTP boundary.
final class StudyApiFixture {
  StudyApiFixture() {
    reader = ReaderApiFixture(
      lastVerse: 80,
      firstVerseText: ' Kadesh. ',
      resourceResponse: respond,
    );
  }
  late final ReaderApiFixture reader;
  final List<Uri> requests = <Uri>[];
  bool offline = false;

  Future<http.Response?> respond(http.Request request) async {
    requests.add(request.url);
    if (offline) throw const SocketException('Fixture offline');
    final Uri url = request.url;
    final String resource = url.path.replaceFirst('/v1/', '');
    Object? body;
    if (url.host == 'dictionaries.getbible.net') {
      final File file = File('test/fixtures/dictionaries_v1/$resource');
      if (file.existsSync()) body = jsonDecode(file.readAsStringSync());
    } else if (url.host == 'commentaries.getbible.net') {
      final Map<String, Object?> fixture =
          jsonDecode(
                File('test/fixtures/commentary_v1.json').readAsStringSync(),
              )
              as Map<String, Object?>;
      body =
          fixture[<String, String>{
            'commentaries.json': 'catalogue',
            'fixture/metadata.json': 'metadata',
            'fixture/books.json': 'coverage',
            'fixture/1/1.json': 'chapter',
            'fixture/1/0.json': 'book_intro',
          }[resource]];
    } else if (url.host == 'bookmarks.getbible.net') {
      final String? file = <String, String>{
        'index.json': 'index',
        'topics.json': 'summaries',
        'locales.json': 'locales',
        'topics/authority-of-the-bible.json': 'single',
        'verses/1/1.json': 'reverse',
        'locales/af.json': 'names_af',
      }[resource];
      if (file != null) {
        body = jsonDecode(
          File('test/fixtures/public_topic_$file.json').readAsStringSync(),
        );
      }
      if (resource == 'locales/en.json') {
        body = <String, Object?>{
          'schema_version': 1,
          'locale': 'en',
          'name': 'English',
          'topics': <String, String>{
            'authority-of-the-bible': 'Authority of the Bible',
            'hope': 'Hope',
          },
        };
      }
    } else if (url.host == 'search.getbible.net') {
      final Map<String, Object?> envelopes =
          jsonDecode(
                File('test/fixtures/service_envelopes.json').readAsStringSync(),
              )
              as Map<String, Object?>;
      body = envelopes['search'];
    }
    return http.Response(
      body == null ? 'Missing Study fixture' : jsonEncode(body),
      body == null ? 404 : 200,
      headers: const <String, String>{
        'content-type': 'application/json',
        'cache-control': 'max-age=600',
      },
    );
  }
}
