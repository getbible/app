import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/study_workspace_journey.dart';

void main() {
  // A short native-style viewport must scroll lazily built dictionary entries
  // into view instead of assuming they exist in the initial cache extent.
  studyWorkspaceJourney(
    viewport: const Size(375, 667),
    platform: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
