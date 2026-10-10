import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/cache.dart';
import 'package:getbible/presentation/reader_screen.dart';

void main() {
  Future<void> pumpNotice(WidgetTester tester, CacheFreshness freshness) async {
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(240, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: Scaffold(body: CacheStatusNotice(freshness: freshness)),
        ),
      ),
    );
  }

  testWidgets('renders verified cache status without an action or overflow', (
    WidgetTester tester,
  ) async {
    await pumpNotice(tester, CacheFreshness.cachedVerified);

    expect(find.text('Verified cached Scripture'), findsOneWidget);
    expect(find.byType(MaterialBanner), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('renders offline cache status at narrow large-text layout', (
    WidgetTester tester,
  ) async {
    await pumpNotice(tester, CacheFreshness.cachedUnverified);

    expect(
      find.text('Offline cached Scripture — verification unavailable'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
