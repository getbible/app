import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/core/ui_strings.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/annotations.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/models/preferences.dart';
import 'package:getbible/main.dart';
import 'package:getbible/presentation/widgets/bookmark_assignment_menu.dart';
import 'package:getbible/presentation/widgets/my_annotations_panel.dart';
import 'package:getbible/presentation/widgets/scripture_verification_badge.dart';
import 'package:getbible/presentation/widgets/scripture_verse_text.dart';
import 'package:getbible/presentation/widgets/study_workspace.dart';
import 'package:getbible/presentation/widgets/topic_verse_list.dart';
import 'package:provider/provider.dart';

import 'support/reader_api_fixture.dart';
import 'support/study_api_fixture.dart';

const _origin = Passage(translation: 'tst', book: 1, chapter: 1, verse: 1);

void main() {
  for (final compact in [false, true]) {
    testWidgets(
      'direct ${compact ? 'paragraph, RTL, dark, 200%' : 'line'} bookmarks add a topic, load Scripture and return to the verse',
      (tester) async {
        _viewport(
          tester,
          compact ? const Size(390, 844) : const Size(1250, 900),
        );
        if (compact) {
          tester.platformDispatcher.textScaleFactorTestValue = 2;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        }
        final fixture = _fixture();
        final state = await _state(tester, fixture);
        late String firstGroup, secondGroup;
        await tester.runAsync(() async {
          await state.bookmarks.initialize(locale: 'en');
          await state.saveMarkingGroup(
            name: 'First personal topic',
            color: '#225588',
          );
          await state.saveMarkingGroup(
            name: 'Second personal topic',
            color: '#885522',
          );
          firstGroup = state.groups
              .singleWhere((group) => group.name == 'First personal topic')
              .id;
          secondGroup = state.groups
              .singleWhere((group) => group.name == 'Second personal topic')
              .id;
          await state.markWholeVerse(
            state.current!.verses.first,
            'Genesis 1:1',
            firstGroup,
          );
          // Public topic memberships have coordinates but no saved quotation.
          // Their text must be resolved, without rewriting membership storage.
          await state.annotations.addMarkingMemberships([
            Marking(
              id: 'public-coordinate-only',
              passage: _origin.copyWith(verse: 3),
              verse: 3,
              start: null,
              end: null,
              quote: '',
              reference: 'Genesis 1:3',
              groupId: secondGroup,
              createdAt: DateTime.utc(2026, 10, 10),
              source: const SharedBookmarkSource(topicId: 'hope'),
            ),
          ]);
          await state.refreshAnnotations();
          if (compact) {
            await state.setLayout(ReaderLayout.paragraph);
            await state.setAppearance(AppearanceMode.dark);
            // Exercise RTL controls independently of the Scripture language;
            // empty packs deliberately use the English fallback labels.
            state.ui = const UiStrings('ar', []);
          }
        });
        await _mount(tester, state);
        final before = await tester.runAsync(
          state.settings.getLastReadingPosition,
        );
        final bookmark = find.byTooltip('Bookmarks for Genesis 1:1');
        expect(bookmark, findsOneWidget);
        expect(tester.getSize(bookmark).width, greaterThanOrEqualTo(48));
        expect(tester.getSize(bookmark).height, greaterThanOrEqualTo(48));
        await tester.tap(bookmark);
        await _settle(tester, state);
        expect(find.byType(BookmarkAssignmentMenu), findsOneWidget);
        expect(find.text('First personal topic'), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Find a topic'), findsNothing);
        expect(
          Theme.of(
            tester.element(find.byType(BookmarkAssignmentMenu)),
          ).brightness,
          compact ? Brightness.dark : Brightness.light,
        );
        if (compact) {
          expect(
            Directionality.of(
              tester.element(find.byType(BookmarkAssignmentMenu)),
            ),
            TextDirection.rtl,
          );
        }
        await tester.tap(find.text('Add another topic'));
        await tester.pumpAndSettle();
        final search = find.widgetWithText(TextField, 'Find a topic');
        await tester.ensureVisible(search);
        await tester.enterText(search, 'Second personal');
        await tester.pumpAndSettle();
        final secondTopic = find.widgetWithText(
          ListTile,
          'Second personal topic',
        );
        await tester.ensureVisible(secondTopic);
        await tester.tap(secondTopic);
        await _settle(tester, state);
        final assignments = state.savedMarkings
            .where((mark) => mark.verse == 1)
            .toList();
        expect(
          assignments.map((mark) => mark.groupId),
          unorderedEquals([firstGroup, secondGroup]),
        );
        expect(assignments.every((mark) => mark.quote == ' Kadesh. '), isTrue);
        expect(find.text('First personal topic'), findsOneWidget);
        final assignedTopic = find.text('Second personal topic');
        await tester.ensureVisible(assignedTopic);
        await tester.tap(assignedTopic);
        await _settle(tester, state);
        expect(find.byType(BookmarkAssignmentMenu), findsNothing);
        expect(find.byType(MyAnnotationsPanel), findsOneWidget);
        final card = find.byKey(const ValueKey('topic-verse:tst/1/1/3:1'));
        final topicScroll = find
            .descendant(
              of: find.byType(MyAnnotationsPanel),
              matching: find.byType(Scrollable),
            )
            .first;
        await tester.scrollUntilVisible(card, 120, scrollable: topicScroll);
        await _until(
          tester,
          () => find
              .descendant(of: card, matching: find.byType(ScriptureVerseText))
              .evaluate()
              .isNotEmpty,
        );
        final loaded = tester.widget<ScriptureVerseText>(
          find.descendant(of: card, matching: find.byType(ScriptureVerseText)),
        );
        expect(loaded.verse.text, 'Verse 3 original.');
        expect(
          find.descendant(of: card, matching: find.text('Genesis 1:3 · TST')),
          findsOneWidget,
        );
        expect(
          fixture.paths.any(
            (path) => Uri.decodeComponent(path).endsWith('Genesis 1:3'),
          ),
          isTrue,
        );
        expect(
          state.savedMarkings
              .singleWhere((mark) => mark.id == 'public-coordinate-only')
              .quote,
          isEmpty,
        );
        expect(state.passage, _origin);
        final back = find.text('Back to verse');
        await tester.scrollUntilVisible(back, -160, scrollable: topicScroll);
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(tester.element(back), alignment: .5);
        await tester.pumpAndSettle();
        expect(back.hitTestable(), findsOneWidget);
        await tester.tap(back);
        await _settle(tester, state);
        expect(find.byType(StudyWorkspace), findsNothing);
        expect(find.byType(TopicVerseList), findsNothing);
        expect(bookmark.hitTestable(), findsOneWidget);
        expect(state.passage, _origin);
        final after = await tester.runAsync(
          state.settings.getLastReadingPosition,
        );
        expect(after?.passage, before?.passage);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    '320px bookmark picker stays above the keyboard and scrolls at 200% text',
    (tester) async {
      _viewport(tester, const Size(320, 720));
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      addTearDown(tester.view.resetViewInsets);
      final state = await _state(tester, _fixture());
      await tester.runAsync(() async {
        await state.bookmarks.initialize(locale: 'en');
        for (var index = 0; index < 12; index++) {
          await state.saveMarkingGroup(
            name: 'Keyboard topic ${index.toString().padLeft(2, '0')}',
            color: '#225588',
          );
        }
      });
      await _mount(tester, state);
      await tester.tap(find.byTooltip('Bookmarks for Genesis 1:1'));
      await _settle(tester, state);
      final menu = find.byType(BookmarkAssignmentMenu);
      final search = find.widgetWithText(TextField, 'Find a topic');
      await tester.ensureVisible(search);
      await tester.enterText(search, 'Keyboard topic');
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(tester.getRect(menu).bottom, lessThanOrEqualTo(440));
      await Scrollable.ensureVisible(tester.element(search), alignment: .2);
      await tester.pumpAndSettle();
      expect(search.hitTestable(), findsOneWidget);
      final list = find.descendant(of: menu, matching: find.byType(ListView));
      await Scrollable.ensureVisible(tester.element(list), alignment: .5);
      await tester.pumpAndSettle();
      final scrollable = find
          .descendant(of: list, matching: find.byType(Scrollable))
          .first;
      final lastTopic = find.widgetWithText(ListTile, 'Keyboard topic 11');
      await tester.scrollUntilVisible(lastTopic, 90, scrollable: scrollable);
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(tester.element(lastTopic), alignment: .5);
      await tester.pumpAndSettle();
      expect(lastTopic.hitTestable(), findsOneWidget);
      expect(tester.getRect(lastTopic).bottom, lessThanOrEqualTo(440));
      await tester.tap(lastTopic);
      await _settle(tester, state);
      expect(state.savedMarkings, hasLength(1));
      expect(
        state.groups
            .singleWhere(
              (group) => group.id == state.savedMarkings.single.groupId,
            )
            .name,
        'Keyboard topic 11',
      );
      expect(tester.takeException(), isNull);
      final close = find.descendant(
        of: menu,
        matching: find.byTooltip('Close'),
      );
      expect(close.hitTestable(), findsOneWidget);
      await tester.tap(close);
      await _settle(tester, state);
      expect(menu, findsNothing);
      expect(state.passage, _origin);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'closing a verse topic clears its return target before generic Study reopens',
    (tester) async {
      _viewport(tester, const Size(1100, 900));
      final state = await _state(tester, _fixture());
      await tester.runAsync(() async {
        await state.bookmarks.initialize(locale: 'en');
        await state.saveMarkingGroup(
          name: 'Return target topic',
          color: '#225588',
        );
        final group = state.groups.singleWhere(
          (group) => group.name == 'Return target topic',
        );
        await state.markWholeVerse(
          state.current!.verses.first,
          'Genesis 1:1',
          group.id,
        );
      });
      await _mount(tester, state);

      Future<void> openFromVerse() async {
        await tester.tap(find.byTooltip('Bookmarks for Genesis 1:1'));
        await _settle(tester, state);
        await tester.tap(find.text('Return target topic'));
        await _settle(tester, state);
        expect(find.text('Back to verse'), findsOneWidget);
      }

      await openFromVerse();
      await tester.tap(find.byTooltip('Close Study tools'));
      await _settle(tester, state);
      expect(find.byType(StudyWorkspace), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Study'));
      await _settle(tester, state);
      // The generic manager must start with all topics and no stale origin.
      expect(find.text('Back to verse'), findsNothing);
      expect(find.text('All topics'), findsNothing);
      final topic = find.text('Return target topic');
      await tester.ensureVisible(topic);
      await tester.tap(topic);
      await _settle(tester, state);
      expect(find.text('All topics'), findsOneWidget);
      expect(find.text('Back to verse'), findsNothing);
      await tester.tap(find.byTooltip('Close Study tools'));
      await _settle(tester, state);
      // Clearing an old target must not suppress a newly captured origin.
      await openFromVerse();
      await tester.tap(find.text('Back to verse'));
      await _settle(tester, state);
      expect(find.byType(StudyWorkspace), findsNothing);
      expect(
        find.byTooltip('Bookmarks for Genesis 1:1').hitTestable(),
        findsOneWidget,
      );
      expect(state.passage, _origin);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'verification stays inline and licensing links to documentation',
    (tester) async {
      _viewport(tester, const Size(1100, 900));
      final state = await _state(tester, _fixture());
      final opened = <String>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        if (call.method == 'launch') {
          opened.add((call.arguments as Map)['url'] as String);
        }
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await _mount(tester, state);
      expect(
        tester.widget<MaterialApp>(find.byType(MaterialApp)).title,
        'getBible',
      );
      await tester.tap(find.byTooltip('Verified Scripture'));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsNothing);
      final notice = find.byType(ScriptureVerificationNotice);
      expect(notice, findsOneWidget);
      final heading = tester.getRect(
        find.widgetWithText(TextButton, 'Fixture 1'),
      );
      expect(tester.getRect(notice).top, greaterThanOrEqualTo(heading.bottom));
      await tester.tap(find.text('getBible API'));
      await tester.pumpAndSettle();
      expect(opened, ['https://getbible.net/api/bible/']);
      await tester.tap(find.byTooltip('Close verification explanation'));
      await tester.pumpAndSettle();
      expect(notice, findsNothing);
      final licensing = find.widgetWithText(TextButton, 'Fixture Bible');
      await tester.ensureVisible(licensing);
      await tester.tap(licensing);
      await tester.pumpAndSettle();
      final attribution = find.text('Powered by getBible APIs.');
      await tester.ensureVisible(attribution);
      expect(find.text('The Word for the world!'), findsOneWidget);
      await tester.tap(attribution);
      await tester.pumpAndSettle();
      expect(opened, [
        'https://getbible.net/api/bible/',
        'https://getbible.net',
      ]);
      expect(state.passage, _origin);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

ReaderApiFixture _fixture() {
  final study = StudyApiFixture();
  return ReaderApiFixture(
    lastVerse: 3,
    firstVerseText: ' Kadesh. ',
    resourceResponse: study.respond,
  );
}

void _viewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<AppState> _state(WidgetTester tester, ReaderApiFixture fixture) async {
  final state = (await tester.runAsync(() async {
    final state = AppState.fromDatabase(
      await LocalDatabase.memory(),
      api: fixture.api,
    );
    await state.settings.saveLastReadingPosition(
      LastReadingPosition(
        passage: _origin,
        verse: 1,
        updatedAt: DateTime.utc(2026, 10, 10),
      ),
    );
    await state.initialize();
    return state;
  }))!;
  addTearDown(state.close);
  return state;
}

Future<void> _mount(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(value: state, child: const GetBibleApp()),
  );
  await _settle(tester, state);
}

Future<void> _settle(WidgetTester tester, AppState state) async {
  await _until(tester, () => !state.loading && !state.bookmarks.busy);
  await tester.pumpAndSettle();
}

Future<void> _until(WidgetTester tester, bool Function() ready) async {
  final deadline = Stopwatch()..start();
  do {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
    await tester.pump(const Duration(milliseconds: 20));
    if (deadline.elapsed > const Duration(seconds: 10)) {
      throw TimeoutException(
        'The reader did not reach its expected visible state.',
      );
    }
  } while (!ready());
}
