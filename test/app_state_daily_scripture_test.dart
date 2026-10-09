import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/app_state.dart';
import 'package:getbible_live/data/api/getbible_api_client.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/cache.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/main.dart';
import 'package:getbible_live/presentation/widgets/native_scripture_text.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';
import 'package:http/testing.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const Passage original = Passage(
    translation: 'kjv',
    book: 1,
    chapter: 1,
    verse: 1,
  );
  late _DailyFixture fixture;
  late AppState state;

  setUp(() async {
    fixture = _DailyFixture();
    state = AppState.fromDatabase(
      await LocalDatabase.memory(),
      api: GetBibleApiClient(client: MockClient(fixture.respond)),
    );
    await state.loadPassage(original);
    expect(state.error, isNull);
    await state.saveVerseNote(1, 'Genesis 1:1', 'Keep this private note.');
    await state.settings.saveDailyScripture(fixture.daily());
  });
  tearDown(() => state.close());

  test(
    'resolves source alias, persists all daily verses and clears emphasis on navigation',
    () async {
      await state.openDailyScripture();
      expect(state.error, isNull);
      expect(
        state.passage,
        const Passage(translation: 'kjv', book: 66, chapter: 1, verse: 9),
      );
      expect(fixture.references, <String>['Revelation 1:9-10,12']);
      expect(state.dailyVerses, <int>[9, 10, 12]);
      expect((await state.settings.getDailyScripture())?.verses, <int>[
        9,
        10,
        12,
      ]);
      expect(
        (await state.settings.getLastReadingPosition())?.passage,
        state.passage,
      );
      await state.openDailyScripture();
      expect(state.dailyVerses, <int>[9, 10, 12]);
      await state.loadPassage(original);
      expect(state.dailyVerses, isEmpty);
      expect(state.notes.single.text, 'Keep this private note.');
    },
  );

  testWidgets(
    'reader renders every daily verse with original text and temporary emphasis',
    (tester) async {
      await tester.runAsync(state.openDailyScripture);
      await tester.pumpWidget(
        ChangeNotifierProvider.value(value: state, child: const GetBibleApp()),
      );
      await tester.pumpAndSettle();
      final List<TextSpan> emphasized = <TextSpan>[];
      void visit(InlineSpan span) {
        if (span is TextSpan) {
          if (span.style?.decoration == TextDecoration.underline)
            emphasized.add(span);
          for (final InlineSpan child
              in span.children ?? const <InlineSpan>[]) {
            visit(child);
          }
        }
      }

      for (final NativeScriptureText text
          in tester.widgetList<NativeScriptureText>(
            find.byType(NativeScriptureText),
          )) {
        visit(text.span);
      }
      expect(emphasized.map((TextSpan span) => span.text), <String>[
        'Original verse 9.',
        'Original verse 10.',
        'Original verse 12.',
      ]);
      expect(state.markings, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('a discovered name needs no alias request', () async {
    await state.settings.saveDailyScripture(
      fixture.daily(book: 'Revelation of John'),
    );
    await state.openDailyScripture();
    expect(state.error, isNull);
    expect(state.passage.book, 66);
    expect(fixture.references, isEmpty);
  });

  for (final String failure in <String>[
    'missing alias',
    'partial query',
    'wrong chapter',
    'missing daily verse',
  ]) {
    test(
      '$failure preserves Scripture, private notes and saved position',
      () async {
        final before = await state.settings.getLastReadingPosition();
        final bibleSnapshot = state.current;
        switch (failure) {
          case 'missing alias':
            fixture.queryStatus = 404;
          case 'partial query':
            fixture.queryVerses = <int>[9];
          case 'wrong chapter':
            fixture.queryChapter = 2;
          case 'missing daily verse':
            await state.settings.saveDailyScripture(
              fixture.daily(book: 'Revelation of John'),
            );
            fixture.chapterVerses = <int>[9, 10];
        }
        await state.openDailyScripture();
        expect(state.error, isNotNull);
        expect(state.loading, isFalse);
        expect(state.passage, original);
        expect(state.current, same(bibleSnapshot));
        expect(state.dailyVerses, isEmpty);
        expect(state.notes.single.text, 'Keep this private note.');
        final after = await state.settings.getLastReadingPosition();
        expect(after?.passage, before?.passage);
        expect(after?.updatedAt, before?.updatedAt);
        expect(
          fixture.paths.any((String path) => path.contains('/49/')),
          isFalse,
        );
      },
    );
  }

  test('failed feed never reopens a stale daily selection', () async {
    await state.settings.saveDailyScripture(fixture.daily(stale: true));
    fixture.feedStatus = 404;
    await state.openDailyScripture();
    expect(state.error, isNotNull);
    expect(state.passage, original);
    expect(state.notes.single.text, 'Keep this private note.');
    expect(fixture.references, isEmpty);
    expect(fixture.paths.any((String path) => path.contains('/49/')), isFalse);
  });

  test(
    'corrupt daily cache is replaced by the current complete feed',
    () async {
      await state.database.writeSetting('dailyScripture', <String, Object?>{
        'broken': true,
      });
      await state.openDailyScripture();
      expect(state.error, isNull);
      expect(state.passage.book, 66);
      expect(state.dailyVerses, <int>[9, 10, 12]);
    },
  );

  test('legacy first-verse cache is refreshed even for today', () async {
    final old = fixture.daily().toJson()..remove('verses');
    old['version'] = 1;
    await state.database.writeSetting('dailyScripture', old);
    await state.openDailyScripture();
    expect(state.error, isNull);
    expect(fixture.paths, contains(Uri.parse(dailyScriptureUrl).path));
    expect(state.dailyVerses, <int>[9, 10, 12]);
  });

  test(
    'Retry repeats failed daily lookup instead of loading the reader default',
    () async {
      await state.close();
      state = AppState.fromDatabase(
        await LocalDatabase.memory(),
        api: GetBibleApiClient(client: MockClient(fixture.respond)),
      );
      fixture.feedStatus = 404;
      await state.initialize();
      expect(state.current, isNull);
      expect(state.error, isNotNull);
      fixture.feedStatus = 200;
      await state.retryReading();
      expect(state.error, isNull);
      expect(state.passage.book, 66);
      expect(state.dailyVerses, <int>[9, 10, 12]);
      expect(
        fixture.paths.any((String path) => path.contains('/49/')),
        isFalse,
      );
    },
  );

  test('a delayed alias response cannot replace a newer navigation', () async {
    fixture.queryWait = Completer<void>();
    final Future<void> opening = state.openDailyScripture();
    await fixture.queryStarted.future;
    final Passage newer = original.copyWith(verse: 3);
    await state.loadPassage(newer);
    fixture.queryWait!.complete();
    await opening;
    expect(state.passage, newer);
    expect(state.dailyVerses, isEmpty);
    expect(state.error, isNull);
    expect((await state.settings.getLastReadingPosition())?.passage, newer);
  });
}

final class _DailyFixture {
  int feedStatus = 200;
  int queryStatus = 200;
  int queryChapter = 1;
  List<int> queryVerses = <int>[9, 10, 12];
  List<int> chapterVerses = <int>[9, 10, 12];
  Completer<void>? queryWait;
  final Completer<void> queryStarted = Completer<void>();
  final List<String> references = <String>[];
  final List<String> paths = <String>[];

  DailyScriptureCache daily({String book = 'Revelation', bool stale = false}) =>
      DailyScriptureCache(
        date:
            (stale
                    ? DateTime.now().subtract(const Duration(days: 1))
                    : DateTime.now())
                .toIso8601String(),
        translation: 'kjv',
        bookName: book,
        chapter: 1,
        verse: 9,
        verses: <int>[9, 10, 12],
        cachedAt: DateTime.now().toUtc(),
      );

  Future<http.Response> respond(http.Request request) async {
    final String path = request.url.path;
    paths.add(path);
    if (request.url.host == 'raw.githubusercontent.com') {
      return _json(<String, Object?>{
        'date': daily().date,
        'book': 'Revelation',
        'chapter': 1,
        'verse': 9,
        'scripture': <Object?>[
          for (final int nr in <int>[9, 10, 12]) <String, Object?>{'nr': nr},
        ],
      }, status: feedStatus);
    }
    if (request.url.host == 'query.getbible.net') {
      references.add(request.url.pathSegments.last);
      if (!queryStarted.isCompleted) queryStarted.complete();
      await queryWait?.future;
      return _json(<String, Object?>{
        'kjv_66_$queryChapter': _chapter(66, queryChapter, queryVerses),
      }, status: queryStatus);
    }
    if (path == '/v3/translations.json') {
      return _json(<String, Object?>{
        'kjv': <String, Object?>{
          'translation': 'King James Version',
          'abbreviation': 'kjv',
          'lang': 'en',
          'language': 'English',
          'direction': 'LTR',
          'sha': 'a' * 40,
        },
      });
    }
    if (path == '/v3/kjv/books.json') {
      return _json(<String, Object?>{
        for (final int book in <int>[1, 66])
          '$book': <String, Object?>{
            'nr': book,
            'name': _name(book),
            'sha': 'b' * 40,
          },
      });
    }
    final match = RegExp(
      r'^/v3/kjv/(1|66)(?:/(chapters|1))?\.(json|sha)$',
    ).firstMatch(path);
    if (match == null) return http.Response('Not found', 404);
    final int book = int.parse(match[1]!);
    final chapter = _chapter(book, 1, book == 1 ? <int>[1, 3] : chapterVerses);
    if (match[2] == 'chapters') {
      return _json(<String, Object?>{
        '1': <String, Object?>{
          'chapter': 1,
          'name': '${_name(book)} 1',
          'sha': sha1.convert(utf8.encode(jsonEncode(chapter))).toString(),
        },
      });
    }
    final Object document = match[2] == '1'
        ? chapter
        : <String, Object?>{
            'nr': book,
            'name': _name(book),
            'translation': 'King James Version',
            'abbreviation': 'kjv',
            'language': 'English',
            'direction': 'LTR',
            'chapters': <Object?>[chapter],
          };
    final String body = jsonEncode(document);
    return http.Response(
      match[3] == 'sha' ? sha1.convert(utf8.encode(body)).toString() : body,
      200,
      headers: <String, String>{'cache-control': 'max-age=600'},
    );
  }

  String _name(int book) => book == 1 ? 'Genesis' : 'Revelation of John';

  Map<String, Object?> _chapter(int book, int chapter, List<int> verses) =>
      <String, Object?>{
        'translation': 'King James Version',
        'abbreviation': 'kjv',
        'language': 'English',
        'direction': 'LTR',
        'book_nr': book,
        'book_name': _name(book),
        'chapter': chapter,
        'name': '${_name(book)} $chapter',
        'verses': <Object?>[
          for (final int verse in verses)
            <String, Object?>{
              'chapter': chapter,
              'verse': verse,
              'name': '${_name(book)} $chapter:$verse',
              'text': 'Original verse $verse.',
            },
        ],
      };

  http.Response _json(Object value, {int status = 200}) => http.Response(
    jsonEncode(value),
    status,
    headers: <String, String>{
      'content-type': 'application/json',
      'cache-control': 'max-age=600',
    },
  );
}
