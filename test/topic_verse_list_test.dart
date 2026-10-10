import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/preferences.dart';
import 'package:getbible/presentation/widgets/scripture_verse_text.dart';
import 'package:getbible/presentation/widgets/topic_verse_list.dart';

import 'support/topic_verse_fixture.dart';

void main() {
  testWidgets(
    'topic cards render complete Scripture, translation and retained selection at 200% text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = TopicVerseFixture();
      final passage = fixture.passages(1).single;
      final item = TopicVerseItem(
        passage: passage,
        reference: 'John 8:1',
        global: true,
        personal: true,
        selectedQuote: 'Original private selection',
        quoteTranslation: 'original',
      );
      TopicVerseItem? opened;
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: CustomScrollView(
                slivers: [
                  TopicVerseList(
                    lookup: fixture.lookup,
                    items: [item],
                    preferences: const ReaderPreferences(
                      readerFont: 'book',
                      textSize: 22,
                    ),
                    onOpen: (item) => opened = item,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scripture = tester.widget<ScriptureVerseText>(
        find.byType(ScriptureVerseText),
      );
      expect(
        scripture.verse.text,
        'kjv full Scripture for verse 1. Second sentence remains visible.',
      );
      expect(scripture.style.fontSize, 22);
      expect(scripture.style.fontFamily, 'Georgia');
      expect(find.text('John 8:1 · KJV'), findsOneWidget);
      await tester.tap(find.text('John 8:1 · KJV'));
      expect(opened, same(item));
      await tester.ensureVisible(find.text('Original private selection'));
      expect(find.text('Saved selection · ORIGINAL'), findsOneWidget);
      expect(item.selectedQuote, 'Original private selection');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('more verses are fetched only after revealing the next page', (
    tester,
  ) async {
    final fixture = TopicVerseFixture();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: CustomScrollView(
            slivers: [
              TopicVerseList(
                lookup: fixture.lookup,
                items: [
                  for (final passage in fixture.passages(45))
                    TopicVerseItem(
                      passage: passage,
                      reference: 'John 8:${passage.verse}',
                    ),
                ],
                onOpen: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(fixture.requests.length, 8);
    await tester.scrollUntilVisible(
      find.text('Show more verses'),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Show more verses'));
    await tester.pumpAndSettle();
    expect(fixture.requests.length, 16);
    expect(tester.takeException(), isNull);
  });
}
