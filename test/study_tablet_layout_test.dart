import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/study_workspace_journey.dart';

void main() {
  // A real keyboard can still be closing when Study opens after native text
  // input. Source metadata must be checked independently of list visibility,
  // then reached through the same scroll interaction available to a user.
  // Later, its show notification arrives between scrolling from the notebook
  // title to its body and focusing that editor. The body must remain editable,
  // and both fields must survive closing and reopening Study while offline.
  studyWorkspaceJourney(
    viewport: const Size(1280, 900),
    platform: TargetPlatformVariant.only(TargetPlatform.android),
    initialKeyboardInset: 420,
    notebookKeyboardInset: 420,
  );
}
