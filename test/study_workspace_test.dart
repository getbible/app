import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/domain/models/bible.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/study_context.dart';
import 'package:getbible_live/presentation/widgets/native_scripture_text.dart';
import 'package:getbible_live/presentation/widgets/study_workspace.dart';
import 'package:getbible_live/services/scripture_text.dart';

const StudyContext study = StudyContext(
  passage: Passage(translation: 'tst', book: 1, chapter: 1, verse: 3),
  bookName: 'Genesis',
  language: 'en',
);

void main() {
  test(
    'selection snapshots preserve original UTF16 and reject split surrogates',
    () {
      const Verse verse = Verse(
        chapter: 1,
        verse: 3,
        name: 'Fixture 1:3',
        text: '  😀 Word.  ',
      );
      StudyContext selection(int start, int end) => StudyContext(
        passage: study.passage,
        bookName: study.bookName,
        language: study.language,
        verse: verse,
        selectionStart: start,
        selectionEnd: end,
      );
      expect(selection(2, 4).selectedText, '😀');
      expect(selection(3, 4).selectedText, isNull);
      expect(selection(4, 11).selectedText, ' Word. ');
      expect(selection(0, 200).selectedText, isNull);
    },
  );

  testWidgets(
    'workspace loads only selected panel, supports RTL large text and Escape',
    (tester) async {
      final List<StudyTab> built = <StudyTab>[];
      int closes = 0;
      await tester.binding.setSurfaceSize(const Size(440, 850));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(440, 850),
              textScaler: TextScaler.linear(2),
            ),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: StudyWorkspace(
                context: study,
                initialTab: StudyTab.commentary,
                panelBuilder: (context, tab) {
                  built.add(tab);
                  return Text('Loaded ${tab.label}');
                },
                onClose: () => closes++,
                onSearchSelection: null,
              ),
            ),
          ),
        ),
      );
      expect(built, <StudyTab>[StudyTab.commentary]);
      await tester.tap(find.byType(DropdownButtonFormField<StudyTab>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Notebooks').last);
      await tester.pumpAndSettle();
      expect(built.last, StudyTab.notes);
      expect(built, isNot(contains(StudyTab.dictionary)));
      expect(tester.takeException(), isNull);
      // The resource chooser remains native keyboard focusable.
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closes, 1);
    },
  );

  testWidgets(
    'single word tap keeps exact original range, double click stays selection',
    (tester) async {
      const Verse verse = Verse(
        chapter: 1,
        verse: 3,
        name: 'Fixture 1:3',
        text: 'First Word.',
      );
      final List<ScriptureTextRange> opened = <ScriptureTextRange>[];
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NativeScriptureText(
              span: const TextSpan(
                text: 'First Word.',
                style: TextStyle(fontSize: 24),
              ),
              mapping: ScriptureParagraphTextMap(<Verse>[verse]),
              onWordTap: (source, range) {
                expect(source, same(verse));
                opened.add(range);
              },
            ),
          ),
        ),
      );
      final Finder text = find.byType(SelectableText);
      final Offset firstWord = tester.getTopLeft(text) + const Offset(15, 15);
      await tester.tapAt(firstWord);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, <ScriptureTextRange>[const ScriptureTextRange(0, 5)]);
      opened.clear();
      await tester.tapAt(firstWord);
      await tester.pump(const Duration(milliseconds: 80));
      await tester.tapAt(firstWord);
      await tester.pump(const Duration(milliseconds: 400));
      expect(opened, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'short 200% landscape keeps resource body and every header action reachable',
    (tester) async {
      tester.view.physicalSize = const Size(680, 260);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(680, 260),
              textScaler: TextScaler.linear(2),
            ),
            child: StudyWorkspace(
              context: study,
              initialTab: StudyTab.notes,
              panelBuilder: (_, tab) => ListView(
                children: const <Widget>[Text('Private notebook body')],
              ),
              onClose: () {},
              onSearchSelection: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.text('Private notebook body')).height,
        greaterThan(0),
      );
      await tester.ensureVisible(find.text('Search selected text'));
      await tester.pumpAndSettle();
      expect(find.text('Search selected text').hitTestable(), findsOneWidget);
    },
  );

  testWidgets('scrolling another verse cancels a pending native word tap', (
    tester,
  ) async {
    const Verse verse = Verse(
      chapter: 1,
      verse: 3,
      name: 'Fixture',
      text: 'First Word.',
    );
    final List<ScriptureTextRange> opened = <ScriptureTextRange>[];
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: <Widget>[
              NativeScriptureText(
                span: const TextSpan(
                  text: 'First Word.',
                  style: TextStyle(fontSize: 24),
                ),
                mapping: ScriptureParagraphTextMap(<Verse>[verse]),
                onWordTap: (_, range) => opened.add(range),
              ),
              const SizedBox(height: 2000),
            ],
          ),
        ),
      ),
    );
    await tester.tapAt(
      tester.getTopLeft(find.byType(SelectableText)) + const Offset(15, 15),
    );
    await tester.pump(const Duration(milliseconds: 80));
    scroll.jumpTo(50);
    await tester.pump(const Duration(milliseconds: 400));
    expect(opened, isEmpty);
  });
}
