import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/core/ui_strings.dart';
import 'package:getbible/data/api/getbible_api_client.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/main.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

const _origin = Passage(translation: 'tst', book: 1, chapter: 1, verse: 3);
const _extendedBook = 1000000042;
const _captureScreenshots = bool.fromEnvironment('CAPTURE_READER_NAV');

void main() {
  setUpAll(() async {
    if (_captureScreenshots) {
      final loader = FontLoader('Roboto')
        ..addFont(rootBundle.load('assets/fonts/Roboto-Regular.ttf'));
      await loader.load();
    }
  });
  for (final compact in [true, false]) {
    testWidgets(
      '${compact ? 'phone' : 'desktop'} passage picker previews discovered books and opens an exact sparse chapter',
      (tester) async {
        _viewport(
          tester,
          compact ? const Size(390, 844) : const Size(1250, 900),
        );
        final fixture = _NavigationFixture();
        final state = await _reader(tester, fixture);
        final before = await tester.runAsync(
          state.settings.getLastReadingPosition,
        );
        final selector = find.byKey(const ValueKey('reader-passage-selector'));
        final translation = find.byKey(
          const ValueKey('reader-translation-selector'),
        );
        expect(tester.getRect(selector).left, lessThanOrEqualTo(112));
        expect(tester.getRect(translation).left, lessThan(80));
        expect(tester.getSize(selector).height, greaterThanOrEqualTo(48));
        await _capture(tester, compact ? 'phone-reader' : 'desktop-reader');
        await tester.tap(selector);
        await _settle(tester);
        await _capture(tester, compact ? 'phone-books' : 'desktop-books');
        await tester.tap(
          find.byKey(const ValueKey('passage-book-$_extendedBook')),
        );
        await _settle(tester);
        expect(find.byKey(const ValueKey('passage-chapter-7')), findsOneWidget);
        expect(find.byKey(const ValueKey('passage-chapter-9')), findsOneWidget);
        await _capture(tester, compact ? 'phone-chapters' : 'desktop-chapters');
        expect(find.byKey(const ValueKey('passage-chapter-1')), findsNothing);
        expect(state.passage, _origin);
        expect(
          (await tester.runAsync(
            state.settings.getLastReadingPosition,
          ))?.updatedAt,
          before?.updatedAt,
        );
        expect(fixture.paths, isNot(contains('/v3/tst/$_extendedBook/1.json')));
        await tester.tap(find.byKey(const ValueKey('passage-chapter-9')));
        await _settle(tester);
        const selected = Passage(
          translation: 'tst',
          book: _extendedBook,
          chapter: 9,
        );
        expect(state.passage, selected);
        expect(state.error, isNull);
        expect(
          find.byKey(const ValueKey('passage-picker-close')),
          findsNothing,
        );
        expect(
          (await tester.runAsync(
            state.settings.getLastReadingPosition,
          ))?.passage,
          selected,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    '320px RTL reader keeps selectors physically left and keyboard picker controls reachable at 200% text',
    (tester) async {
      _viewport(tester, const Size(320, 900));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      final fixture = _NavigationFixture();
      final state = await _reader(tester, fixture, rtl: true);
      final passage = find.byKey(const ValueKey('reader-passage-selector'));
      final translation = find.byKey(
        const ValueKey('reader-translation-selector'),
      );
      final mobile = find.byKey(
        const ValueKey('reader-mobile-passage-selector'),
      );
      for (final control in [passage, translation, mobile]) {
        final bounds = tester.getRect(control);
        expect(bounds.left, lessThanOrEqualTo(112));
        expect(bounds.right, lessThanOrEqualTo(320));
        expect(bounds.height, greaterThanOrEqualTo(48));
      }
      expect(Directionality.of(tester.element(translation)), TextDirection.rtl);
      for (final tooltip in [
        state.ui('previousChapter'),
        state.ui('nextChapter'),
      ]) {
        expect(tester.getRect(find.byTooltip(tooltip)).left, lessThan(96));
      }
      await tester.tap(passage);
      await _settle(tester);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      addTearDown(tester.view.resetViewInsets);
      await tester.pumpAndSettle();
      final search = find.byKey(const ValueKey('passage-picker-search'));
      await tester.ensureVisible(search);
      await tester.enterText(search, 'Extended');
      await tester.pumpAndSettle();
      final book = find.byKey(const ValueKey('passage-book-$_extendedBook'));
      await tester.ensureVisible(book);
      expect(book.hitTestable(), findsOneWidget);
      expect(tester.getRect(book).bottom, lessThanOrEqualTo(620));
      await tester.tap(book);
      await _settle(tester);
      final chapter = find.byKey(const ValueKey('passage-chapter-9'));
      await tester.ensureVisible(chapter);
      expect(chapter.hitTestable(), findsOneWidget);
      expect(tester.getRect(chapter).bottom, lessThanOrEqualTo(620));
      await _capture(tester, 'phone-rtl-large-keyboard');
      expect(state.passage, _origin);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'translation preview is separate; explicit Open preserves book and chapter',
    (tester) async {
      _viewport(tester, const Size(390, 844));
      final fixture = _NavigationFixture();
      final state = await _reader(tester, fixture);
      final before = await tester.runAsync(
        state.settings.getLastReadingPosition,
      );
      await _chooseTranslation(tester, 'alt');
      expect(find.text('Description for Alternate Bible'), findsOneWidget);
      await _capture(tester, 'phone-translation-details');
      expect(find.text('Fixture public domain license'), findsOneWidget);
      expect(state.passage, _origin);
      expect(
        fixture.paths.where((path) => path.startsWith('/v3/alt')),
        isEmpty,
      );
      await tester.tap(find.byKey(const ValueKey('translation-picker-close')));
      await _settle(tester);
      expect(state.passage, _origin);
      expect(
        (await tester.runAsync(
          state.settings.getLastReadingPosition,
        ))?.updatedAt,
        before?.updatedAt,
      );
      await _chooseTranslation(tester, 'alt');
      final open = find.byKey(const ValueKey('translation-picker-open'));
      await tester.ensureVisible(open);
      await tester.tap(open);
      await _settle(tester);
      const selected = Passage(translation: 'alt', book: 1, chapter: 1);
      expect(state.passage, selected);
      expect(state.error, isNull);
      expect(
        find.byKey(const ValueKey('translation-picker-close')),
        findsNothing,
      );
      expect(
        (await tester.runAsync(state.settings.getLastReadingPosition))?.passage,
        selected,
      );
      expect(
        fixture.paths.where((path) => path.startsWith('/v3/partial')),
        isEmpty,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'a translation lacking the current book waits for an explicit discovered chapter',
    (tester) async {
      _viewport(tester, const Size(1250, 900));
      final fixture = _NavigationFixture();
      final state = await _reader(tester, fixture);
      final before = await tester.runAsync(
        state.settings.getLastReadingPosition,
      );
      await _chooseTranslation(tester, 'partial');
      final open = find.byKey(const ValueKey('translation-picker-open'));
      await tester.ensureVisible(open);
      await tester.tap(open);
      await _settle(tester);
      expect(find.byKey(const ValueKey('passage-book-1')), findsNothing);
      expect(
        find.byKey(const ValueKey('passage-book-$_extendedBook')),
        findsOneWidget,
      );
      expect(state.passage, _origin);
      expect(fixture.paths, isNot(contains('/v3/partial.json')));
      expect(
        (await tester.runAsync(
          state.settings.getLastReadingPosition,
        ))?.updatedAt,
        before?.updatedAt,
      );
      await tester.tap(
        find.byKey(const ValueKey('passage-book-$_extendedBook')),
      );
      await _settle(tester);
      expect(state.passage, _origin);
      await tester.tap(find.byKey(const ValueKey('passage-chapter-7')));
      await _settle(tester);
      const selected = Passage(
        translation: 'partial',
        book: _extendedBook,
        chapter: 7,
      );
      expect(state.passage, selected);
      expect(state.error, isNull);
      expect(find.byKey(const ValueKey('passage-picker-close')), findsNothing);
      expect(
        find.byKey(const ValueKey('translation-picker-close')),
        findsNothing,
      );
      expect(
        (await tester.runAsync(state.settings.getLastReadingPosition))?.passage,
        selected,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'closing a pending chapter open preserves the reader and saved position',
    (tester) async {
      _viewport(tester, const Size(390, 844));
      final fixture = _NavigationFixture();
      final state = await _reader(tester, fixture);
      final before = await tester.runAsync(
        state.settings.getLastReadingPosition,
      );
      await tester.tap(find.byKey(const ValueKey('reader-passage-selector')));
      await _settle(tester);
      await tester.tap(
        find.byKey(const ValueKey('passage-book-$_extendedBook')),
      );
      await _settle(tester);
      fixture.delayChapter = Completer<void>();
      await tester.tap(find.byKey(const ValueKey('passage-chapter-7')));
      await _until(tester, () => fixture.chapterStarted.isCompleted);
      await tester.tap(find.byKey(const ValueKey('passage-picker-close')));
      await tester.pumpAndSettle();
      fixture.delayChapter!.complete();
      await _until(tester, () => !state.loading);
      await _settle(tester);
      expect(state.passage, _origin);
      expect(state.error, isNull);
      final after = await tester.runAsync(
        state.settings.getLastReadingPosition,
      );
      expect(after?.passage, before?.passage);
      expect(after?.updatedAt, before?.updatedAt);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

Future<void> _chooseTranslation(
  WidgetTester tester,
  String abbreviation,
) async {
  await tester.tap(find.byKey(const ValueKey('reader-translation-selector')));
  await _settle(tester);
  await tester.tap(find.byKey(const ValueKey('translation-picker-choice')));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const ValueKey('translation-picker-search')),
    abbreviation,
  );
  await tester.pumpAndSettle();
  final candidate = find.byKey(
    ValueKey('translation-picker-option-$abbreviation'),
  );
  await tester.ensureVisible(candidate);
  await tester.tap(candidate);
  await _settle(tester);
}

void _viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<AppState> _reader(
  WidgetTester tester,
  _NavigationFixture fixture, {
  bool rtl = false,
}) async {
  final state = (await tester.runAsync(() async {
    final state = AppState.fromDatabase(
      await LocalDatabase.memory(),
      api: fixture.api,
    );
    await state.loadPassage(_origin);
    if (_captureScreenshots) await state.setReaderFont('system');
    if (rtl) state.ui = const UiStrings('ar', []);
    return state;
  }))!;
  addTearDown(() async {
    if (fixture.delayChapter case final pending? when !pending.isCompleted) {
      pending.complete();
    }
    await tester.runAsync(state.close);
  });
  expect(state.error, isNull);
  await tester.pumpWidget(
    RepaintBoundary(
      key: const ValueKey('reader-navigation-capture'),
      child: ChangeNotifierProvider.value(
        value: state,
        child: const GetBibleApp(),
      ),
    ),
  );
  await _settle(tester);
  return state;
}

Future<void> _capture(WidgetTester tester, String name) async {
  if (!_captureScreenshots) return;
  await tester.pumpAndSettle();
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey('reader-navigation-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final directory = Directory('/tmp/getbible-navigation')
      ..createSync(recursive: true);
    File(
      '${directory.path}/$name.png',
    ).writeAsBytesSync(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 25)),
    );
    await tester.pump();
  }
  await tester.pumpAndSettle();
}

Future<void> _until(WidgetTester tester, bool Function() done) async {
  final watch = Stopwatch()..start();
  while (!done()) {
    if (watch.elapsed > const Duration(seconds: 5))
      fail('Navigation did not reach its expected milestone.');
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump();
  }
}

final class _NavigationFixture {
  _NavigationFixture() {
    api = GetBibleApiClient(client: MockClient(_respond));
  }
  late final GetBibleApiClient api;
  final List<String> paths = [];
  Completer<void>? delayChapter;
  final chapterStarted = Completer<void>();
  static const _titles = {
    'tst': 'Fixture Bible',
    'alt': 'Alternate Bible',
    'partial': 'Only Extended Bible',
  };

  Future<http.Response> _respond(http.Request request) async {
    final path = request.url.path;
    paths.add(path);
    if (path == '/v3/translations.json') {
      return _json({for (final id in _titles.keys) id: _translation(id)});
    }
    final match = RegExp(r'^/v3/(tst|alt|partial)/(.*)$').firstMatch(path);
    if (match == null)
      return http.Response('Unavailable fixture resource', 404);
    final id = match[1]!;
    final resource = match[2]!;
    final books = id == 'partial' ? [_extendedBook] : [1, _extendedBook];
    if (resource == 'books.json') {
      return _json({
        for (final book in books)
          '$book': {
            'nr': book,
            'name': _bookName(book),
            'sha': _hash(_book(id, book)),
          },
      });
    }
    final chapterIndex = RegExp(r'^(\d+)/chapters.json$').firstMatch(resource);
    if (chapterIndex != null) {
      final book = int.parse(chapterIndex[1]!);
      return _json({
        for (final chapter in _chapters(book))
          '$chapter': {
            'chapter': chapter,
            'name': '${_bookName(book)} $chapter',
            'sha': _hash(_chapter(id, book, chapter)),
          },
      });
    }
    final bookDocument = RegExp(r'^(\d+)\.(json|sha)$').firstMatch(resource);
    if (bookDocument != null) {
      final body = _book(id, int.parse(bookDocument[1]!));
      return bookDocument[2] == 'sha'
          ? http.Response(_hash(body), 200)
          : _json(body);
    }
    final chapterDocument = RegExp(
      r'^(\d+)/(\d+)\.(json|sha)$',
    ).firstMatch(resource);
    if (chapterDocument != null) {
      final book = int.parse(chapterDocument[1]!);
      final chapter = int.parse(chapterDocument[2]!);
      if (book == _extendedBook &&
          chapter == 7 &&
          chapterDocument[3] == 'json' &&
          delayChapter != null) {
        if (!chapterStarted.isCompleted) chapterStarted.complete();
        await delayChapter!.future;
      }
      final body = _chapter(id, book, chapter);
      return chapterDocument[3] == 'sha'
          ? http.Response(_hash(body), 200)
          : _json(body);
    }
    return http.Response('Unavailable fixture resource', 404);
  }

  List<int> _chapters(int book) => book == 1 ? [1] : [7, 9];
  String _bookName(int book) => book == 1 ? 'Genesis' : 'Extended Book';
  Map<String, Object?> _translation(String id) => {
    'translation': _titles[id],
    'abbreviation': id,
    'lang': 'en',
    'language': 'English',
    'direction': 'LTR',
    'description': 'Description for ${_titles[id]}',
    'distribution_license': 'Fixture public domain license',
    'sha': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  };
  Map<String, Object?> _book(String id, int book) => {
    ..._translation(id),
    'nr': book,
    'name': _bookName(book),
    'chapters': [
      for (final chapter in _chapters(book)) _chapter(id, book, chapter),
    ],
  };
  Map<String, Object?> _chapter(String id, int book, int chapter) => {
    ..._translation(id),
    'book_nr': book,
    'book_name': _bookName(book),
    'chapter': chapter,
    'name': '${_bookName(book)} $chapter',
    'verses': [
      for (final verse in [1, 3])
        {
          'chapter': chapter,
          'verse': verse,
          'name': '${_bookName(book)} $chapter:$verse',
          'text': '${_titles[id]} verse $verse.',
        },
    ],
  };
  String _hash(Object body) =>
      sha1.convert(utf8.encode(jsonEncode(body))).toString();
  http.Response _json(Object body) => http.Response(
    jsonEncode(body),
    200,
    headers: {
      'content-type': 'application/json',
      'cache-control': 'max-age=600',
    },
  );
}
