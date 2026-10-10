import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/offline_controller.dart';
import 'package:getbible/core/request_cancellation.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/offline_resource.dart';
import 'package:getbible/domain/repositories/offline_resource_repository.dart';
import 'package:getbible/presentation/widgets/offline_setup_panel.dart';

void main() {
  testWidgets(
    'resource filter text and focus survive download progress and activation',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = await LocalDatabase.memory();
      final installer = _CatalogueInstaller();
      final controller = OfflineController(
        store: SqlOfflineResourceStore(database),
        installers: [installer],
      );
      final field = find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.labelText == 'Find a resource',
      );
      EditableText input() => tester.widget<EditableText>(
        find.descendant(of: field, matching: find.byType(EditableText)),
      );
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: OfflineSetupPanel(controller: controller)),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Browse catalogue'));
        await tester.pumpAndSettle();
        await tester.enterText(field, 'KJV');
        await tester.pumpAndSettle();
        expect(find.text('Greek dictionary'), findsNothing);
        await tester.scrollUntilVisible(
          find.text('Install'),
          200,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Install'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, 'Install'));
        await tester.pumpAndSettle();
        expect(installer.downloadStarted.isCompleted, isTrue);
        expect(
          input().controller.text,
          'KJV',
          reason:
              'Starting a download must not erase the visible catalogue filter.',
        );
        await tester.ensureVisible(field);
        await tester.pumpAndSettle();
        await tester.tap(field);
        await tester.pump();
        tester.testTextInput.updateEditingValue(
          const TextEditingValue(
            text: 'KJV',
            selection: TextSelection(baseOffset: 0, extentOffset: 3),
          ),
        );
        await tester.pump();
        expect(input().focusNode.hasFocus, isTrue);
        installer.releaseDownload.complete();
        await tester.pumpAndSettle();
        expect(controller.installed, hasLength(1));
        expect(
          input().controller.text,
          'KJV',
          reason:
              'An installed card must not detach the user-visible filter from its active value.',
        );
        expect(
          input().controller.selection,
          const TextSelection(baseOffset: 0, extentOffset: 3),
        );
        expect(
          input().focusNode.hasFocus,
          isTrue,
          reason:
              'Background activation must not take keyboard focus from catalogue search.',
        );
        await tester.enterText(field, 'Greek');
        await tester.pumpAndSettle();
        expect(input().controller.text, 'Greek');
        expect(find.text('Greek dictionary'), findsOneWidget);
        expect(find.text('Keep offline'), findsOneWidget);
        expect(find.text('Install'), findsNothing);
        expect(find.text('No matching resources.'), findsNothing);
      } finally {
        controller.cancel();
        if (!installer.releaseDownload.isCompleted) {
          installer.releaseDownload.complete();
        }
        await tester.pumpAndSettle();
        await controller.close();
        await tester.pumpWidget(const SizedBox.shrink());
        controller.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'offline manager opens local state without discovery, then explicitly installs',
    (tester) async {
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final installer = _Installer();
      final controller = OfflineController(
        store: SqlOfflineResourceStore(database),
        installers: [installer],
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: OfflineSetupPanel(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      expect(installer.discoveryRequests, 0);
      await tester.tap(find.text('Browse catalogue'));
      await tester.pumpAndSettle();
      expect(installer.discoveryRequests, 1);
      await tester.scrollUntilVisible(
        find.text('Install'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Install'));
      await tester.pumpAndSettle();
      expect(installer.installRequests, 0);
      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await tester.pumpAndSettle();
      expect(installer.installRequests, 1);
      expect(controller.installed, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'manager exclusions remove public copies and clear keeps private data and choices',
    (tester) async {
      tester.view.physicalSize = const Size(800, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = await LocalDatabase.memory();
      final installer = _Installer(kind: OfflineResourceKind.dictionary);
      final freshness = SqlOfflineFreshnessStore(database);
      final controller = OfflineController(
        store: SqlOfflineResourceStore(database),
        freshness: freshness,
        installers: [installer],
      );
      await database.writeSetting('private-note', {'text': 'retain this'});
      await controller.discover();
      await tester.runAsync(() => controller.install(installer.resource));
      try {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: OfflineSetupPanel(controller: controller)),
          ),
        );
        await tester.pumpAndSettle();
        final toggle = find.byType(CheckboxListTile).first;
        await tester.scrollUntilVisible(
          toggle,
          150,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        expect(tester.widget<CheckboxListTile>(toggle).value, isTrue);
        await tester.tap(toggle);
        await tester.pumpAndSettle();
        expect(controller.installed, isEmpty);
        expect(
          await freshness.readExcludedKeys(),
          contains(installer.resource.key),
        );
        final clear = find.widgetWithText(TextButton, 'Clear downloads');
        await tester.scrollUntilVisible(
          clear,
          -200,
          scrollable: find
              .descendant(
                of: find.byType(ListView),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(clear);
        await tester.pumpAndSettle();
        expect(find.text('Clear downloads?'), findsOneWidget);
        await tester.tap(find.widgetWithText(FilledButton, 'Clear downloads'));
        await tester.pumpAndSettle();
        expect(controller.installed, isEmpty);
        expect(
          await database.readSetting('private-note'),
          contains('retain this'),
        );
        expect(
          await freshness.readExcludedKeys(),
          contains(installer.resource.key),
        );
        expect(installer.installRequests, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await controller.close();
        controller.dispose();
        await database.close();
      }
    },
  );

  testWidgets(
    'installed resources and failure details fit compact RTL at 200 percent text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final database = await LocalDatabase.memory();
      addTearDown(database.close);
      final installer = _Installer();
      final controller = OfflineController(
        store: SqlOfflineResourceStore(database),
        installers: [installer],
      );
      addTearDown(controller.dispose);
      await tester.runAsync(() => controller.install(installer.resource));
      controller.error =
          'A previous update did not complete. Existing installed data is preserved.';
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: Scaffold(body: OfflineSetupPanel(controller: controller)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.drag(find.byType(ListView), const Offset(0, -800));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

final class _Installer implements OfflineResourceInstaller {
  _Installer({this.kind = OfflineResourceKind.bible});
  final OfflineResourceKind kind;
  late final resource = OfflineResourceDescriptor(
    kind: kind,
    id: 'test',
    title: 'Test Bible',
    sourceUri: Uri.parse('https://example.test/v3'),
    revision: 'one',
    attribution: 'Public domain',
  );
  @override
  Uri get sourceUri => resource.sourceUri;
  @override
  Future<OfflineResourceDescriptor> resolve(
    OfflineResourceKind kind,
    String id,
    RequestCancellation cancellation,
  ) async => resource;
  @override
  Future<OfflineResourceDescriptor> checkRevision(
    OfflineResourceDescriptor value,
    RequestCancellation cancellation,
  ) async => resource;
  int discoveryRequests = 0;
  int installRequests = 0;
  @override
  Set<OfflineResourceKind> get supportedKinds => {kind};
  @override
  Future<List<OfflineResourceDescriptor>> discover(
    RequestCancellation cancellation,
  ) async {
    discoveryRequests++;
    return [resource];
  }

  @override
  Future<void> install(
    OfflineResourceDescriptor resource,
    OfflineInstallSink sink,
    RequestCancellation cancellation,
  ) async {
    installRequests++;
    await sink.writeDocument('chapter', '{"saved":true}');
  }
}

final class _CatalogueInstaller implements OfflineResourceInstaller {
  final downloadStarted = Completer<void>();
  final releaseDownload = Completer<void>();
  final bible = OfflineResourceDescriptor(
    kind: OfflineResourceKind.bible,
    id: 'kjv',
    title: 'King James Version (KJV)',
    sourceUri: Uri.parse('https://example.test/v3'),
    revision: 'one',
  );
  final dictionary = OfflineResourceDescriptor(
    kind: OfflineResourceKind.dictionary,
    id: 'greek',
    title: 'Greek dictionary',
    sourceUri: Uri.parse('https://example.test/v3'),
    revision: 'one',
  );
  @override
  Uri get sourceUri => bible.sourceUri;
  @override
  Future<OfflineResourceDescriptor> resolve(
    OfflineResourceKind kind,
    String id,
    RequestCancellation cancellation,
  ) async => kind == OfflineResourceKind.bible ? bible : dictionary;
  @override
  Future<OfflineResourceDescriptor> checkRevision(
    OfflineResourceDescriptor value,
    RequestCancellation cancellation,
  ) => resolve(value.kind, value.id, cancellation);
  @override
  Set<OfflineResourceKind> get supportedKinds => {
    OfflineResourceKind.bible,
    OfflineResourceKind.dictionary,
  };
  @override
  Future<List<OfflineResourceDescriptor>> discover(
    RequestCancellation cancellation,
  ) async => [bible, dictionary];
  @override
  Future<void> install(
    OfflineResourceDescriptor resource,
    OfflineInstallSink sink,
    RequestCancellation cancellation,
  ) async {
    sink.progress(1, 2, 'Validating source');
    downloadStarted.complete();
    await cancellation.bind(releaseDownload.future);
    await sink.writeDocument('chapter', '{"saved":true}');
    sink.progress(2, 2, 'Complete');
  }
}
