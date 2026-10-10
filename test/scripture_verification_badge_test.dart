import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/cache.dart';
import 'package:getbible/presentation/widgets/scripture_verification_badge.dart';

void main() {
  Future<void> pumpBadge(WidgetTester tester, CacheFreshness freshness) async {
    var expanded = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) => Column(
              children: [
                ScriptureVerificationBadge(
                  freshness: freshness,
                  expanded: expanded,
                  onPressed: () => setState(() => expanded = !expanded),
                ),
                if (expanded)
                  ScriptureVerificationNotice(
                    freshness: freshness,
                    onClose: () => setState(() => expanded = false),
                  ),
                const Text('Scripture remains available'),
              ],
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('verified status toggles a dismissible inline explanation', (
    tester,
  ) async {
    await pumpBadge(tester, CacheFreshness.cachedVerified);
    await tester.tap(find.byTooltip('Verified Scripture'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.textContaining('hash published by getBible'), findsOneWidget);
    expect(find.text('getBible API'), findsOneWidget);
    expect(find.text('Scripture remains available'), findsOneWidget);
    await tester.tap(find.byTooltip('Close verification explanation'));
    await tester.pumpAndSettle();
    expect(find.byType(ScriptureVerificationNotice), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('offline status explains unverified saved Scripture', (
    tester,
  ) async {
    await pumpBadge(tester, CacheFreshness.cachedUnverified);
    await tester.tap(find.byTooltip('Saved Scripture'));
    await tester.pumpAndSettle();
    expect(find.textContaining('last known good copy'), findsOneWidget);
    expect(find.textContaining('matches the current source'), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('notice wraps at compact width and enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 850);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpBadge(tester, CacheFreshness.cachedVerified);
    await tester.tap(find.byTooltip('Verified Scripture'));
    await tester.pumpAndSettle();
    expect(find.text('getBible API'), findsOneWidget);
    expect(
      tester.getRect(find.byType(ScriptureVerificationNotice)).right,
      lessThanOrEqualTo(320),
    );
    expect(tester.takeException(), isNull);
  });
}
