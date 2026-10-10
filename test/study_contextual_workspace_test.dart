import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/presentation/widgets/study_workspace.dart';

import 'support/dictionary_fixture.dart';

void main() {
  testWidgets(
    'contextual Study keeps selected Scripture and exposes two tabs',
    (tester) async {
      final tabs = <StudyTab>[];
      var searches = 0;
      var closes = 0;
      final selected = dictionaryContext(word: 'commanded', strongs: ['G1781']);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: StudyWorkspace(
              context: selected,
              contextual: true,
              initialTab: StudyTab.dictionary,
              panelBuilder: (_, tab) {
                tabs.add(tab);
                return Text('Panel ${tab.name}');
              },
              onClose: () => closes++,
              onSearchSelection: () => searches++,
            ),
          ),
        ),
      );
      expect(find.text('Study Scripture'), findsOneWidget);
      expect(find.text('KJV · John 1:1'), findsOneWidget);
      expect(find.text('commanded'), findsOneWidget);
      expect(find.byType(DropdownButtonFormField<StudyTab>), findsNothing);
      expect(find.byType(Tab), findsNWidgets(2));
      expect(tabs.toSet(), {StudyTab.dictionary});
      await tester.tap(find.text('Commentaries'));
      await tester.pumpAndSettle();
      expect(find.text('Panel commentary'), findsOneWidget);
      expect(find.text('commanded'), findsOneWidget);
      await tester.tap(find.text('Search selection'));
      expect(searches, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(closes, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact RTL Study remains usable with large text and short height',
    (tester) async {
      tester.view.physicalSize = const Size(320, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: const TextScaler.linear(2)),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: child!,
            ),
          ),
          home: Scaffold(
            body: StudyWorkspace(
              context: dictionaryContext(
                word: 'A selected phrase with several words',
              ),
              contextual: true,
              initialTab: StudyTab.dictionary,
              panelBuilder: (_, _) => const Text('Definition body'),
              onClose: () {},
              onSearchSelection: () {},
            ),
          ),
        ),
      );
      expect(find.text('Definition body').hitTestable(), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Commentaries'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
