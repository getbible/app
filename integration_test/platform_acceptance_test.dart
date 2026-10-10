import 'dart:io';

import 'package:integration_test/integration_test.dart';

import '../test/support/migration_journey.dart';
import '../test/support/offline_portability_journey.dart';
import '../test/support/reader_upgrade_journey.dart';
import '../test/support/study_workspace_journey.dart';
import '../test/support/worker_performance_journey.dart';

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.reportData = {'platform': Platform.operatingSystem};
  migrationJourney();
  readerUpgradeJourney(nativeClipboard: true);
  studyWorkspaceJourney(useDeviceViewport: true);
  offlinePortabilityJourney(
    useDeviceViewport: true,
    capture: () async {
      if (Platform.isAndroid) {
        await binding.convertFlutterSurfaceToImage();
        await binding.pump();
      }
      if (Platform.isAndroid || Platform.isIOS) {
        await binding.takeScreenshot('installed-reader-device-viewport');
      }
      // The pinned integration_test callback restores Android's surface in
      // its registered test teardown; no public revert method exists.
    },
  );
  workerPerformanceJourney(
    record: (metrics) {
      binding.reportData!['workerPerformance'] = metrics;
    },
  );
}
