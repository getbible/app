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
