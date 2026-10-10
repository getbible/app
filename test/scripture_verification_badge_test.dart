import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/cache.dart';
import 'package:getbible/presentation/widgets/scripture_verification_badge.dart';

void main() {
  Future<void> pumpBadge(WidgetTester tester, CacheFreshness freshness) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ScriptureVerificationBadge(freshness: freshness)),
      ),
    );
  }

  testWidgets('verified badge opens hash-verification details', (
    WidgetTester tester,
  ) async {
    await pumpBadge(tester, CacheFreshness.cachedVerified);

    expect(find.byIcon(Icons.verified_user_outlined), findsOneWidget);
    expect(find.text('VERIFIED'), findsNothing);

    await tester.tap(find.byTooltip('Verified Scripture'));
    await tester.pumpAndSettle();

    expect(find.text('Scripture verified'), findsOneWidget);
    expect(find.textContaining('hash published by GetBible'), findsOneWidget);
    expect(find.text('Close'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('unverified offline badge explains saved copy', (
    WidgetTester tester,
  ) async {
    await pumpBadge(tester, CacheFreshness.cachedUnverified);

    await tester.tap(find.byTooltip('Saved Scripture'));
    await tester.pumpAndSettle();

    expect(find.text('Saved for offline reading'), findsOneWidget);
    expect(find.textContaining('last known good copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
