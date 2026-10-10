import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/study_workspace_journey.dart';

void main() {
  // A real keyboard can still be closing when Study opens after native text
  // input. Source metadata must be checked independently of list visibility,
  // then reached through the same scroll interaction available to a user.
  studyWorkspaceJourney(
    viewport: const Size(1280, 900),
    platform: TargetPlatformVariant.only(TargetPlatform.android),
    initialKeyboardInset: 420,
  );
}
