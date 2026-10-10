import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/bible.dart';
import 'package:getbible/presentation/widgets/native_scripture_text.dart';
import 'package:getbible/services/scripture_text.dart';

void main() {
  for (final paragraph in [false, true]) {
    testWidgets(
      'semantic Copy excludes inline controls in ${paragraph ? 'paragraph' : 'verse'} text',
      (tester) async {
        final semantics = tester.ensureSemantics();
        final writes = <String>[];
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          (call) async {
            if (call.method == 'Clipboard.setData') {
              writes.add(
                (call.arguments as Map<Object?, Object?>)['text']! as String,
              );
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
        const verses = [
          Verse(
            chapter: 1,
            verse: 1,
            name: 'John 1:1',
            text: '  First 😀 e\u0301.\n',
          ),
          Verse(chapter: 1, verse: 2, name: 'John 1:2', text: 'שלום 中文連續 '),
        ];
        final source = paragraph ? verses : [verses.first];
        final mapping = ScriptureParagraphTextMap(
          source,
          versePrefix: paragraph ? (_) => '\uFFFC' : null,
          verseSuffix: (_) => '\uFFFC',
        );
        var bookmarks = 0;
        final spans = <InlineSpan>[];
        for (var index = 0; index < source.length; index++) {
          if (index > 0) spans.add(const TextSpan(text: ' '));
          if (paragraph) {
            spans.add(WidgetSpan(child: Text('${source[index].verse}')));
          }
          spans.add(TextSpan(text: source[index].text));
          spans.add(
            WidgetSpan(
              child: IconButton(
                tooltip: 'Bookmark verse ${source[index].verse}',
                onPressed: () => bookmarks++,
                icon: const Icon(Icons.bookmark_border),
              ),
            ),
          );
        }
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: NativeScriptureText(
                span: TextSpan(
                  style: const TextStyle(fontSize: 22),
                  children: spans,
                ),
                mapping: mapping,
              ),
            ),
          ),
        );
        final editable = tester.state<EditableTextState>(
          find.byType(EditableText),
        );
        editable.widget.focusNode.requestFocus();
        await tester.pump();
        editable.selectAll(SelectionChangedCause.keyboard);
        await tester.pumpAndSettle();
        final owner = tester
            .renderObject(find.byType(NativeScriptureText))
            .owner!
            .semanticsOwner!;
        final nodes = <SemanticsNode>[];
        void visit(SemanticsNode node) {
          if (node.getSemanticsData().hasAction(SemanticsAction.copy)) {
            nodes.add(node);
          }
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(owner.rootSemanticsNode!);
        expect(nodes, hasLength(1));
        final node = nodes.single;
        expect(
          node.getSemanticsData().hasAction(SemanticsAction.setSelection),
          isTrue,
        );
        owner.performAction(node.id, SemanticsAction.copy);
        await tester.pump();
        expect(writes, [source.map((verse) => verse.text).join(' ')]);
        expect(editable.textEditingValue.text, mapping.text);
        expect(editable.textEditingValue.selection.end, mapping.text.length);
        // Accessibility still owns the native selection action and its original
        // UTF-16 offsets, including a reversed selection around a surrogate pair.
        final emoji =
            mapping.locations.first.$2.start + source.first.text.indexOf('😀');
        owner.performAction(node.id, SemanticsAction.setSelection, {
          'base': emoji + 2,
          'extent': emoji,
        });
        await tester.pumpAndSettle();
        owner.performAction(node.id, SemanticsAction.copy);
        await tester.pump();
        expect(writes, [source.map((verse) => verse.text).join(' '), '😀']);
        expect(editable.textEditingValue.text, mapping.text);
        expect(editable.textEditingValue.selection.baseOffset, emoji + 2);
        expect(editable.textEditingValue.selection.extentOffset, emoji);
        // Inline controls retain their own accessible actions; the wrapper must
        // not flatten the field and its bookmark into one merged control.
        final buttons = <SemanticsNode>[];
        void findButton(SemanticsNode candidate) {
          final data = candidate.getSemanticsData();
          if (data.tooltip == 'Bookmark verse 1' &&
              data.hasAction(SemanticsAction.tap)) {
            buttons.add(candidate);
          }
          candidate.visitChildren((child) {
            findButton(child);
            return true;
          });
        }

        findButton(owner.rootSemanticsNode!);
        expect(buttons, hasLength(1));
        owner.performAction(buttons.single.id, SemanticsAction.tap);
        await tester.pump();
        expect(bookmarks, 1);
        expect(tester.takeException(), isNull);
        semantics.dispose();
      },
      variant: TargetPlatformVariant.only(TargetPlatform.linux),
    );
  }
}
