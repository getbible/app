import 'package:integration_test/integration_test.dart';

import '../test/support/reader_upgrade_journey.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  readerUpgradeJourney(nativeClipboard: true);
}
