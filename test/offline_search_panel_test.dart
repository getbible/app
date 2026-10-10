import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/online_search_controller.dart';
import 'package:getbible/core/request_cancellation.dart';
import 'package:getbible/domain/models/online_search.dart';
import 'package:getbible/domain/models/service_envelopes.dart';
import 'package:getbible/domain/repositories/search_repository.dart';
import 'package:getbible/presentation/widgets/search_panel.dart';

void main() {
  testWidgets(
    'a complete installed Bible is the default while explicit online remains selected',
    (tester) async {
      final online = _SearchRecorder();
      final installed = _SearchRecorder();
      final controller = OnlineSearchController(
        repository: online,
        installedRepository: installed,
        isTranslationInstalled: (translation) => translation == 'fx',
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPanel(
              controller: controller,
              translation: 'fx',
              books: const [],
              onOpen: (_) async {},
            ),
          ),
        ),
      );
      expect(find.text('Installed Bible (offline)'), findsOneWidget);
      await tester.enterText(
        find.byKey(const ValueKey<String>('online-search-query')),
        'faith',
      );
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(online.requests, isEmpty);
      expect(
        installed.requests.single.criteria.diacritics,
        SearchDiacritics.exact,
      );
      await tester.tap(find.text('Installed Bible (offline)'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Online search').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('online-search-query')),
        'hope',
      );
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(online.requests.last.text, 'hope');
      expect(installed.requests, hasLength(1));
      expect(controller.mode, SearchExecutionMode.online);
    },
  );

  test(
    'controller chooses the installed source only for an available Bible',
    () async {
      final online = _SearchRecorder();
      final installed = _SearchRecorder();
      final controller = OnlineSearchController(
        repository: online,
        installedRepository: installed,
        isTranslationInstalled: (translation) => translation == 'fx',
      );
      addTearDown(controller.dispose);
      await controller.search('fx', 'faith');
      expect(controller.mode, SearchExecutionMode.installed);
      expect(
        installed.requests.single.criteria.diacritics,
        SearchDiacritics.exact,
      );
      await controller.search('other', 'hope');
      expect(controller.mode, SearchExecutionMode.online);
      expect(online.requests.single.translation, 'other');
      await controller.search('fx', 'love', mode: SearchExecutionMode.online);
      expect(online.requests.last.text, 'love');
      expect(installed.requests, hasLength(1));
    },
  );

  testWidgets(
    'installed source is explicit and submits supported local criteria without online search',
    (tester) async {
      final online = _SearchRecorder();
      final installed = _SearchRecorder();
      final controller = OnlineSearchController(
        repository: online,
        installedRepository: installed,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SearchPanel(
              controller: controller,
              translation: 'fx',
              books: const [],
              onOpen: (_) async {},
            ),
          ),
        ),
      );
      expect(find.text('Online search'), findsOneWidget);
      expect(online.requests, isEmpty);
      expect(installed.requests, isEmpty);
      await tester.tap(find.text('Online search'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Installed Bible (offline)').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey<String>('online-search-query')),
        'faith',
      );
      await tester.tap(find.byTooltip('Search'));
      await tester.pumpAndSettle();
      expect(online.requests, isEmpty);
      expect(installed.requests.single.text, 'faith');
      expect(
        installed.requests.single.criteria.diacritics,
        SearchDiacritics.exact,
      );
      expect(installed.requests.single.criteria.sort, SearchSort.canonical);
      expect(installed.requests.single.criteria.proximity, isNull);
      expect(controller.mode, SearchExecutionMode.installed);
      expect(tester.takeException(), isNull);
    },
  );
}

class _SearchRecorder implements SearchRepository {
  final requests = <OnlineSearchRequest>[];
  @override
  Future<OnlineSearchPage> search(
    OnlineSearchRequest request, {
    RequestCancellation? cancellation,
  }) async {
    requests.add(request);
    return const OnlineSearchPage(
      kind: SearchResultKind.search,
      hits: [],
      total: 0,
      returned: 0,
      engineVersion: 1,
      offset: 0,
      hasMore: false,
      sourceSha: null,
    );
  }
}
