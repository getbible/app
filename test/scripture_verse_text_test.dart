import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/presentation/widgets/scripture_editorial.dart';
import 'package:getbible/presentation/widgets/scripture_verse_text.dart';

void main() {
  testWidgets('rich verse preserves exact native selectable and copied text', (
    WidgetTester tester,
  ) async {
    const String text = '  God\t made 😀\n e\u0301. ';
    String? clipboard;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard =
              (call.arguments as Map<Object?, Object?>)['text'] as String?;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    final Verse verse = _verse(text);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ScriptureVerseText(
            verse: verse,
            style: const TextStyle(fontSize: 20),
          ),
        ),
      ),
    );
    final SelectableText widget = tester.widget<SelectableText>(
      find.byType(SelectableText),
    );
    expect(widget.textSpan!.toPlainText(), text);
    expect(widget.selectionEnabled, isTrue);
    final EditableTextState editable = tester.state<EditableTextState>(
      find.byType(EditableText),
    );
    editable.selectAll(SelectionChangedCause.keyboard);
    await tester.pump();
    expect(editable.textEditingValue.selection.start, 0);
    expect(editable.textEditingValue.selection.end, text.length);
    editable.copySelection(SelectionChangedCause.keyboard);
    await tester.pump();
    expect(clipboard, text);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'custom context retains native Copy and original UTF16 selection',
    (WidgetTester tester) async {
      const String text = 'A 😀 original verse';
      bool built = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScriptureVerseText(
              verse: _verse(text),
              style: const TextStyle(fontSize: 20),
              contextMenuBuilder:
                  (BuildContext context, EditableTextState editable) {
                    built = true;
                    expect(editable.textEditingValue.text, text);
                    expect(
                      editable.contextMenuButtonItems.any(
                        (ContextMenuButtonItem item) =>
                            item.type == ContextMenuButtonType.copy,
                      ),
                      isTrue,
                    );
                    return AdaptiveTextSelectionToolbar.buttonItems(
                      anchors: editable.contextMenuAnchors,
                      buttonItems: editable.contextMenuButtonItems,
                    );
                  },
            ),
          ),
        ),
      );
      await tester.tap(find.byType(SelectableText));
      await tester.pump();
      final EditableTextState editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      editable.userUpdateTextEditingValue(
        const TextEditingValue(
          text: text,
          selection: TextSelection(baseOffset: 2, extentOffset: 4),
        ),
        SelectionChangedCause.keyboard,
      );
      editable.showToolbar();
      await tester.pumpAndSettle();
      expect(built, isTrue);
      expect(editable.textEditingValue.selection.textInside(text), '😀');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'paragraph rich spans retain whitespace in a scaled native document',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final Verse first = _verse('  God\t made 😀\n e\u0301. ');
      const Verse second = Verse(
        chapter: 1,
        verse: 5,
        name: 'Genesis 1:5',
        text: 'שלום 中文連續 ',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 700),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: Builder(
                builder: (BuildContext context) => Padding(
                  padding: const EdgeInsets.all(16),
                  child: SelectableText.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        scriptureVerseSpan(
                          context: context,
                          verse: first,
                          style: const TextStyle(fontSize: 20),
                        ),
                        const TextSpan(text: ' '),
                        scriptureVerseSpan(
                          context: context,
                          verse: second,
                          style: const TextStyle(fontSize: 20),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final SelectableText selectable = tester.widget<SelectableText>(
        find.byType(SelectableText),
      );
      expect(
        selectable.textSpan!.toPlainText(),
        '${first.text} ${second.text}',
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final TextDirection direction in TextDirection.values) {
    testWidgets(
      'rich editorial and introduction stay legible at 200% $direction',
      (WidgetTester tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 700));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final Verse verse = _verse(
          '  שלום 中文 😀\noriginal punctuation, and e\u0301. ',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(
                size: Size(320, 700),
                textScaler: TextScaler.linear(2),
              ),
              child: Scaffold(
                body: Directionality(
                  textDirection: direction,
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: <Widget>[
                      ScriptureIntroductionSection(
                        titles: const <ScriptureTitle>[
                          ScriptureTitle(<String, Object?>{
                            'text': 'Source introduction title',
                          }),
                        ],
                        introduction: const <ScriptureIntroduction>[
                          ScriptureIntroduction(<String, Object?>{
                            'text':
                                'Original introduction prose with no verse coordinate.',
                          }),
                        ],
                        textStyle: const TextStyle(fontSize: 20),
                        textDirection: direction,
                      ),
                      ScriptureEditorialHeading(
                        heading: const EditorialHeading(<String, Object?>{
                          'order': 0,
                          'type': 'heading',
                          'anchor': <String, Object?>{
                            'verse': 1,
                            'edge': 'before',
                          },
                          'text': 'Editorial source heading',
                          'heading_type': 'section',
                          'canonical': false,
                        }),
                        textStyle: const TextStyle(fontSize: 20),
                        textDirection: direction,
                      ),
                      ScriptureVerseText(
                        verse: verse,
                        style: const TextStyle(fontSize: 20),
                        textDirection: direction,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.byType(ScriptureVerseText),
          120,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        final SelectableText selectable = tester.widget<SelectableText>(
          find.descendant(
            of: find.byType(ScriptureVerseText),
            matching: find.byType(SelectableText),
          ),
        );
        expect(selectable.textSpan!.toPlainText(), verse.text);
        expect(selectable.textDirection, direction);
        expect(tester.takeException(), isNull);
      },
    );
  }
}

Verse _verse(String text) => Verse.fromJson(<String, Object?>{
  'chapter': 1,
  'verse': 1,
  'name': 'Genesis 1:1',
  'text': text,
  'tokens': <Object?>[
    <String, Object?>{'token': 'God', 'word_start': 1, 'word_end': 1},
  ],
  'spans': <Object?>[
    <String, Object?>{
      'tag': 'divineName',
      'span': 'God',
      'word_start': 1,
      'word_end': 1,
      'token_start': 0,
      'token_end': 0,
    },
  ],
});
