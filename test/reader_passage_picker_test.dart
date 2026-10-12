import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/presentation/widgets/reader_passage_picker.dart';

const _books = <BibleBook>[
  BibleBook(number: 1, name: 'Genesis', sha: 'genesis'),
  BibleBook(
    number: 2,
    name: 'The entire published name of a book with an unusually long title',
    sha: 'long-book',
  ),
  BibleBook(number: 43, name: 'John', sha: 'john'),
  BibleBook(number: 99, name: 'Additional published book', sha: 'extra'),
];
const _passage = Passage(translation: 'tst', book: 1, chapter: 3, verse: 5);
const _chapters = <ChapterInfo>[
  ChapterInfo(
    chapter: 0,
    name: 'Published book introduction',
    sha: 'intro',
    isIntroduction: true,
  ),
  ChapterInfo(chapter: 1, name: 'Chapter 1', sha: 'one'),
  ChapterInfo(chapter: 3, name: 'Chapter 3', sha: 'three'),
  ChapterInfo(chapter: 150, name: 'Chapter 150', sha: 'one-fifty'),
];

void main() {
  testWidgets(
    'book browsing preserves passage until a published chapter opens',
    (tester) async {
      final requests = <int>[];
      final opened = <Passage>[];
      await _pumpPicker(
        tester,
        loadChapters: (book) async {
          requests.add(book);
          return _chapters;
        },
        onOpen: (passage) async => opened.add(passage),
      );
      expect(find.text('Old Testament'), findsOneWidget);
      expect(find.text('New Testament'), findsOneWidget);
      expect(find.byTooltip('Additional published book'), findsOneWidget);
      expect(find.text('TST'), findsOneWidget);
      final selected = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('passage-book-1')),
      );
      final unselected = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('passage-book-43')),
      );
      expect(selected.style!.backgroundColor!.resolve({}), isNotNull);
      expect(unselected.style!.backgroundColor?.resolve({}), isNull);

      await tester.tap(find.byKey(const ValueKey('passage-book-99')));
      await tester.pumpAndSettle();
      expect(requests, [99]);
      expect(opened, isEmpty);
      expect(find.byKey(const ValueKey('passage-chapter-0')), findsOneWidget);
      expect(find.text('Introduction'), findsOneWidget);
      expect(find.byKey(const ValueKey('passage-chapter-3')), findsOneWidget);
      expect(find.byKey(const ValueKey('passage-chapter-150')), findsOneWidget);
      expect(find.byKey(const ValueKey('passage-chapter-2')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('passage-chapter-0')));
      await tester.pumpAndSettle();
      expect(opened, [const Passage(translation: 'tst', book: 99, chapter: 0)]);
      expect(opened.single.verse, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'selected chapter is highlighted and search retains source names',
    (tester) async {
      await _pumpPicker(tester);
      await tester.enterText(
        find.byKey(const ValueKey('passage-picker-search')),
        'GEN',
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('passage-book-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('passage-book-43')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('passage-book-1')));
      await tester.pumpAndSettle();
      final selected = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('passage-chapter-3')),
      );
      final other = tester.widget<OutlinedButton>(
        find.byKey(const ValueKey('passage-chapter-1')),
      );
      expect(selected.style!.backgroundColor!.resolve({}), isNotNull);
      expect(other.style!.backgroundColor?.resolve({}), isNull);
      await tester.tap(find.byKey(const ValueKey('passage-picker-back')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('passage-book-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('passage-book-43')), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'GEN',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Back invalidates chapter results from the previously browsed book',
    (tester) async {
      final late = Completer<List<ChapterInfo>>();
      await _pumpPicker(
        tester,
        loadChapters: (book) async => book == 1
            ? late.future
            : [const ChapterInfo(chapter: 23, name: 'John 23', sha: 'john-23')],
      );
      await tester.tap(find.byKey(const ValueKey('passage-book-1')));
      await tester.pump();
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('passage-picker-back')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('passage-book-43')));
      await tester.pumpAndSettle();
      late.complete(_chapters);
      await tester.pumpAndSettle();
      expect(find.text('John'), findsOneWidget);
      expect(find.byKey(const ValueKey('passage-chapter-23')), findsOneWidget);
      expect(find.byKey(const ValueKey('passage-chapter-150')), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('closing during chapter discovery discards a late failure', (
    tester,
  ) async {
    final late = Completer<List<ChapterInfo>>();
    var closed = false;
    await _pumpPicker(
      tester,
      loadChapters: (_) => late.future,
      onClose: () => closed = true,
    );
    await tester.tap(find.byKey(const ValueKey('passage-book-1')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('passage-picker-close')));
    expect(closed, isTrue);
    await tester.pumpWidget(const SizedBox());
    late.completeError(StateError('Discovery failed after dismissal'));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('discovery and passage failures retain the picker with Retry', (
    tester,
  ) async {
    var discoveryAttempts = 0;
    var openAttempts = 0;
    final opened = <Passage>[];
    await _pumpPicker(
      tester,
      loadChapters: (_) async {
        if (++discoveryAttempts == 1) throw StateError('Offline');
        return _chapters;
      },
      onOpen: (passage) async {
        if (++openAttempts == 1) throw StateError('Chapter unavailable');
        opened.add(passage);
      },
    );
    await tester.tap(find.byKey(const ValueKey('passage-book-1')));
    await tester.pumpAndSettle();
    expect(find.text('The passage could not be loaded.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('passage-picker-retry')));
    await tester.pumpAndSettle();
    expect(discoveryAttempts, 2);
    await tester.tap(find.byKey(const ValueKey('passage-chapter-150')));
    await tester.pumpAndSettle();
    expect(openAttempts, 1);
    expect(opened, isEmpty);
    expect(find.text('The passage could not be loaded.'), findsOneWidget);
    expect(find.byKey(const ValueKey('passage-chapter-150')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('passage-picker-retry')));
    await tester.pumpAndSettle();
    expect(openAttempts, 2);
    expect(opened, [const Passage(translation: 'tst', book: 1, chapter: 150)]);
    expect(find.text('The passage could not be loaded.'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'empty books, filtered books and chapters report truthful states',
    (tester) async {
      await _pumpPicker(tester, books: const []);
      expect(find.text('This translation has no books.'), findsOneWidget);
      await _pumpPicker(tester, loadChapters: (_) async => []);
      await tester.enterText(find.byType(TextField), 'not a published book');
      await tester.pumpAndSettle();
      expect(find.text('No matching resources.'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      await tester.enterText(find.byType(TextField), 'Genesis');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('passage-book-1')));
      await tester.pumpAndSettle();
      expect(find.text('This book has no chapters.'), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
    },
  );

  testWidgets(
    'narrow RTL with 200% text and keyboard keeps every target reachable',
    (tester) async {
      await _pumpPicker(
        tester,
        size: const Size(320, 640),
        textScale: 2,
        keyboardHeight: 360,
        direction: TextDirection.rtl,
      );
      expect(tester.getSize(find.byType(ReaderPassagePicker)).height, 280);
      final longBook = find.byKey(const ValueKey('passage-book-2'));
      await tester.ensureVisible(longBook);
      await tester.pumpAndSettle();
      expect(longBook.hitTestable(), findsOneWidget);
      expect(tester.getSize(longBook).height, greaterThanOrEqualTo(48));
      final longName = tester.widget<Text>(
        find.descendant(of: longBook, matching: find.byType(Text)),
      );
      expect(find.byTooltip(_books[1].name), findsOneWidget);
      expect(longName.semanticsLabel, _books[1].name);
      expect(longName.maxLines, isNull);
      expect(longName.overflow, isNull);
      final extraBook = find.byKey(const ValueKey('passage-book-99'));
      await tester.ensureVisible(extraBook);
      await tester.pumpAndSettle();
      expect(extraBook.hitTestable(), findsOneWidget);
      await tester.tap(extraBook);
      await tester.pumpAndSettle();
      final chapter = find.byKey(const ValueKey('passage-chapter-150'));
      await tester.ensureVisible(chapter);
      await tester.pumpAndSettle();
      expect(chapter.hitTestable(), findsOneWidget);
      expect(tester.getSize(chapter).height, greaterThanOrEqualTo(48));
      expect(tester.getSize(chapter).width, greaterThanOrEqualTo(48));
      final close = find.byKey(const ValueKey('passage-picker-close'));
      await tester.ensureVisible(close);
      await tester.pumpAndSettle();
      expect(close.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keyboard traversal opens a book with Enter', (tester) async {
    final requests = <int>[];
    await _pumpPicker(
      tester,
      loadChapters: (book) async {
        requests.add(book);
        return _chapters;
      },
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // Close.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // Find a book.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // First book.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(requests, [1]);
    expect(find.byKey(const ValueKey('passage-chapter-3')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'compact labels distinguish prefixes and preserve source script',
    (tester) async {
      const books = <BibleBook>[
        BibleBook(number: 50, name: 'Philippians', sha: 'philippians'),
        BibleBook(number: 57, name: 'Philemon', sha: 'philemon'),
        BibleBook(number: 46, name: '1 Corinthians', sha: '1-corinthians'),
        BibleBook(number: 47, name: '2 Corinthians', sha: '2-corinthians'),
        BibleBook(number: 67, name: 'Same', sha: 'same-a'),
        BibleBook(number: 68, name: 'Same', sha: 'same-b'),
        BibleBook(number: 74, name: 'a\u0301bcdef', sha: 'graphemes'),
        BibleBook(number: 75, name: 'בראשית', sha: 'hebrew', direction: 'RTL'),
      ];
      await _pumpPicker(tester, books: books);
      expect(find.text('Phili'), findsOneWidget);
      expect(find.text('Phile'), findsOneWidget);
      expect(find.text('1\u00a0Cor'), findsOneWidget);
      expect(find.text('2\u00a0Cor'), findsOneWidget);
      expect(find.text('Same · 67'), findsOneWidget);
      expect(find.text('Same · 68'), findsOneWidget);
      expect(find.text('a\u0301bc'), findsOneWidget);
      final hebrew = tester.widget<Text>(find.text('ברא'));
      expect(hebrew.textDirection, TextDirection.rtl);
      expect(hebrew.semanticsLabel, 'בראשית');
      expect(find.byTooltip('בראשית'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('passage-book-75')));
      await tester.pumpAndSettle();
      expect(find.text('בראשית'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('book grid uses four phone columns and eight desktop columns', (
    tester,
  ) async {
    final books = <BibleBook>[
      for (var number = 1; number <= 12; number++)
        BibleBook(number: number, name: '$number Book', sha: '$number'),
    ];
    Future<void> check(Size size, int columns) async {
      await _pumpPicker(tester, books: books, size: size);
      final first = tester.getTopLeft(
        find.byKey(const ValueKey('passage-book-1')),
      );
      final last = tester.getTopLeft(
        find.byKey(ValueKey('passage-book-$columns')),
      );
      final next = tester.getTopLeft(
        find.byKey(ValueKey('passage-book-${columns + 1}')),
      );
      expect(last.dy, first.dy);
      expect(next.dy, greaterThan(first.dy));
      expect(tester.takeException(), isNull);
    }

    await check(const Size(320, 740), 4);
    await check(const Size(680, 740), 8);
  });
}

Future<void> _pumpPicker(
  WidgetTester tester, {
  List<BibleBook> books = _books,
  Future<List<ChapterInfo>> Function(int)? loadChapters,
  Future<void> Function(Passage)? onOpen,
  VoidCallback? onClose,
  Size size = const Size(640, 760),
  double textScale = 1,
  double keyboardHeight = 0,
  TextDirection direction = TextDirection.ltr,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(textScale),
            viewInsets: EdgeInsets.only(bottom: keyboardHeight),
          ),
          child: Directionality(
            textDirection: direction,
            child: Scaffold(
              body: ReaderPassagePicker(
                books: books,
                passage: _passage,
                loadChapters: loadChapters ?? (_) async => _chapters,
                onOpen: onOpen ?? (_) async {},
                onClose: onClose ?? () {},
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
