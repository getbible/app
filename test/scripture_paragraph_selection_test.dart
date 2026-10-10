import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/presentation/widgets/scripture_paragraph_selection.dart';
import 'package:getbible/services/scripture_text.dart';

void main() {
  for (final TargetPlatform platform in <TargetPlatform>[
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    testWidgets(
      'native select-all and keyboard Copy excludes verse markers on $platform',
      (WidgetTester tester) async {
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
        const List<Verse> verses = <Verse>[
          Verse(
            chapter: 1,
            verse: 1,
            name: 'Genesis 1:1',
            text: '  First\n😀 e\u0301. ',
          ),
          Verse(chapter: 1, verse: 3, name: 'Genesis 1:3', text: 'שלום 中文連續 '),
        ];
        final ScriptureParagraphTextMap mapping = ScriptureParagraphTextMap(
          verses,
          versePrefix: (_) => '\uFFFC',
        );
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: ScriptureParagraphSelection(
                mapping: mapping,
                child: SelectableText.rich(
                  TextSpan(
                    style: const TextStyle(fontSize: 20),
                    children: <InlineSpan>[
                      const WidgetSpan(child: Text('1')),
                      TextSpan(text: verses.first.text),
                      const TextSpan(text: ' '),
                      const WidgetSpan(child: Text('3')),
                      TextSpan(text: verses.last.text),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.byType(SelectableText));
        await tester.pump();
        final LogicalKeyboardKey modifier = platform == TargetPlatform.macOS
            ? LogicalKeyboardKey.metaLeft
            : LogicalKeyboardKey.controlLeft;
        await _shortcut(tester, modifier, LogicalKeyboardKey.keyA);
        final EditableTextState editable = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        expect(editable.textEditingValue.selection.start, 0);
        expect(editable.textEditingValue.selection.end, mapping.text.length);
        await _shortcut(tester, modifier, LogicalKeyboardKey.keyC);
        expect(clipboard, '${verses.first.text} ${verses.last.text}');
        expect(clipboard, isNot(contains('\uFFFC')));
        expect(editable.textEditingValue.text, mapping.text);
        expect(editable.textEditingValue.selection.end, mapping.text.length);
        expect(tester.takeException(), isNull);
      },
      variant: TargetPlatformVariant.only(platform),
    );
  }

  testWidgets(
    'keyboard Copy keeps an exact reversed UTF16 verse selection',
    (WidgetTester tester) async {
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
      const Verse verse = Verse(
        chapter: 1,
        verse: 1,
        name: 'Genesis 1:1',
        text: 'A 😀 e\u0301. ',
      );
      final ScriptureParagraphTextMap mapping = ScriptureParagraphTextMap(
        const <Verse>[verse],
        versePrefix: (_) => '\uFFFC',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ScriptureParagraphSelection(
              mapping: mapping,
              child: SelectableText.rich(
                TextSpan(
                  children: <InlineSpan>[
                    const WidgetSpan(child: Text('1')),
                    TextSpan(text: verse.text),
                  ],
                ),
              ),
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
        TextEditingValue(
          text: mapping.text,
          selection: const TextSelection(baseOffset: 5, extentOffset: 3),
        ),
        SelectionChangedCause.keyboard,
      );
      await _shortcut(
        tester,
        LogicalKeyboardKey.controlLeft,
        LogicalKeyboardKey.keyC,
      );
      expect(clipboard, '😀');
      expect(editable.textEditingValue.selection.baseOffset, 5);
      expect(editable.textEditingValue.selection.extentOffset, 3);
      expect(tester.takeException(), isNull);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.linux),
  );
}

Future<void> _shortcut(
  WidgetTester tester,
  LogicalKeyboardKey modifier,
  LogicalKeyboardKey key,
) async {
  await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}
