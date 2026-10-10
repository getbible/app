import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
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

  for (final freshness in [
    CacheFreshness.cachedVerified,
    CacheFreshness.cachedUnverified,
  ]) {
    testWidgets('$freshness exposes one accessible verification button', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      await pumpBadge(tester, freshness);
      final label = freshness == CacheFreshness.cachedVerified
          ? 'Verified Scripture'
          : 'Saved Scripture';
      final owner = tester
          .renderObject(find.byType(ScriptureVerificationBadge))
          .owner!
          .semanticsOwner!;
      SemanticsNode verificationButton() {
        final matches = <SemanticsNode>[];
        void visit(SemanticsNode node) {
          final data = node.getSemanticsData();
          if (!node.isMergedIntoParent &&
              data.flagsCollection.isButton &&
              (data.label == label || data.tooltip == label)) {
            matches.add(node);
          }
          node.visitChildren((child) {
            visit(child);
            return true;
          });
        }

        visit(owner.rootSemanticsNode!);
        // Count exported role-bearing nodes, including non-actionable outer
        // buttons. Merged descendants are not exported as separate controls.
        expect(matches, hasLength(1));
        expect(
          matches.single.getSemanticsData().hasAction(SemanticsAction.tap),
          isTrue,
        );
        return matches.single;
      }

      final button = verificationButton();
      expect(
        button.getSemanticsData().flagsCollection.isExpanded,
        Tristate.isFalse,
      );
      owner.performAction(button.id, SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(find.byType(ScriptureVerificationNotice), findsOneWidget);
      expect(
        verificationButton().getSemanticsData().flagsCollection.isExpanded,
        Tristate.isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(
        verificationButton().getSemanticsData().flagsCollection.isFocused,
        Tristate.isTrue,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pumpAndSettle();
      expect(find.byType(ScriptureVerificationNotice), findsNothing);
      expect(
        verificationButton().getSemanticsData().flagsCollection.isExpanded,
        Tristate.isFalse,
      );
      expect(tester.takeException(), isNull);
      semantics.dispose();
    });
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
