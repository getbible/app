import 'dart:convert';
import 'dart:io';

import 'package:getbible/core/json.dart';
import 'package:getbible/data/api/api_transport.dart';
import 'package:getbible/data/repositories/api_dictionary_repository.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/study_context.dart';
import 'package:getbible/domain/repositories/study_preferences_repository.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

final class DictionaryFixture {
  final List<Uri> requests = <Uri>[];
  late final ApiTransport transport = ApiTransport(
    client: MockClient((http.Request request) async {
      requests.add(request.url);
      final File file = File(
        'test/fixtures/dictionaries_v1/${request.url.path.replaceFirst('/v1/', '')}',
      );
      return file.existsSync()
          ? http.Response.bytes(
              utf8.encode(file.readAsStringSync()),
              200,
              headers: <String, String>{'cache-control': 'max-age=600'},
            )
          : http.Response('not found', 404);
    }),
  );
  late final ApiDictionaryRepository repository = ApiDictionaryRepository(
    transport,
  );
  void close() => transport.close();
}

JsonMap dictionaryJson(String path) => requireJsonMap(
  jsonDecode(File('test/fixtures/dictionaries_v1/$path').readAsStringSync()),
  'dictionary fixture',
);

final class MemoryStudyPreferences implements StudyPreferencesRepository {
  final Map<String, String> dictionaries = <String, String>{};
  bool failWrites = false;
  @override
  Future<String?> dictionary(String language, String family) async =>
      dictionaries['$language:$family'];
  @override
  Future<void> setDictionary(
    String language,
    String family,
    String module,
  ) async {
    if (failWrites) throw const FormatException('Storage unavailable');
    dictionaries['$language:$family'] = module;
  }

  @override
  Future<String?> commentary(String language) async => null;
  @override
  Future<void> setCommentary(String language, String module) async {}
  @override
  Future<bool> topicFollowed(String scopedTopic) async => false;
  @override
  Future<void> setTopicFollowed(String scopedTopic, bool followed) async {}
  @override
  Future<bool> topicHidden(String scopedTopic) async => false;
  @override
  Future<void> setTopicHidden(String scopedTopic, bool hidden) async {}
}

StudyContext dictionaryContext({
  String word = 'Word',
  String language = 'en',
  List<String> strongs = const <String>[],
}) {
  final Verse verse = Verse.fromJson(<String, Object?>{
    'verse': 1,
    'chapter': 1,
    'text': word,
    if (strongs.isNotEmpty)
      'tokens': <Object?>[
        <String, Object?>{
          'token': word,
          'word_start': 1,
          'word_end': 1,
          'lemma': <String, Object?>{'strong': strongs},
        },
      ],
  });
  return StudyContext(
    passage: const Passage(translation: 'kjv', book: 43, chapter: 1, verse: 1),
    bookName: 'John',
    language: language,
    verse: verse,
    selectionStart: 0,
    selectionEnd: word.length,
  );
}
