import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/offline_controller.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/database/local_database.dart';
import 'package:getbible_live/domain/models/offline_resource.dart';
import 'package:getbible_live/domain/repositories/offline_resource_repository.dart';
import 'package:getbible_live/presentation/widgets/offline_setup_panel.dart';

void main() {
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
      await tester.ensureVisible(find.text('Install'));
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
  final resource = OfflineResourceDescriptor(
    kind: OfflineResourceKind.bible,
    id: 'test',
    title: 'Test Bible',
    sourceUri: Uri.parse('https://example.test/v3'),
    revision: 'one',
    attribution: 'Public domain',
  );
  int discoveryRequests = 0;
  int installRequests = 0;
  @override
  Set<OfflineResourceKind> get supportedKinds => {OfflineResourceKind.bible};
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
