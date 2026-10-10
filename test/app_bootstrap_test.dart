import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/presentation/app_bootstrap.dart';

void main() {
  testWidgets(
    'storage failure stays visible and Retry opens the same resource',
    (tester) async {
      var attempts = 0;
      var discarded = 0;
      final retry = Completer<String>();
      await tester.pumpWidget(
        AppBootstrap<String>(
          create: () async {
            attempts++;
            if (attempts == 1) throw StateError('local storage denied');
            return retry.future;
          },
          discard: (_) async {
            discarded++;
          },
          builder: (_, resource) => MaterialApp(home: Text(resource)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Local storage is unavailable'), findsOneWidget);
      expect(find.text('Your saved data has not been reset.'), findsOneWidget);
      expect(find.textContaining('local storage denied'), findsNothing);
      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      button.onPressed!();
      button.onPressed!();
      await tester.pump();
      expect(
        attempts,
        2,
        reason: 'Repeated Retry must not race database opens.',
      );
      expect(find.text('Opening local data'), findsOneWidget);
      retry.complete('Reader is ready');
      await tester.pumpAndSettle();
      expect(find.text('Reader is ready'), findsOneWidget);
      expect(discarded, 0);
    },
  );

  testWidgets('late startup resources close when the startup surface is gone', (
    tester,
  ) async {
    final opening = Completer<String>();
    final discarded = <String>[];
    await tester.pumpWidget(
      AppBootstrap<String>(
        create: () => opening.future,
        discard: (resource) async {
          discarded.add(resource);
        },
        builder: (_, resource) => MaterialApp(home: Text(resource)),
      ),
    );
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    opening.complete('unused reader');
    await tester.pumpAndSettle();
    expect(discarded, ['unused reader']);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup failure remains usable in a compact large-text window', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 360);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      AppBootstrap<String>(
        create: () async => throw StateError('unavailable'),
        discard: (_) async {},
        builder: (_, resource) => MaterialApp(home: Text(resource)),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Retry'));
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
