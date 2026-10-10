import 'package:flutter/material.dart';

import 'support/offline_portability_journey.dart';
import 'support/study_workspace_journey.dart';

/// These full journeys also run on real emulator/simulator viewports in native
/// CI. The compact host pass catches unreachable controls and layout regressions
/// quickly while retaining the same storage, worker and zero-HTTP assertions.
void main() {
  const phoneViewport = Size(390, 844);
  studyWorkspaceJourney(viewport: phoneViewport);
  offlinePortabilityJourney(viewport: phoneViewport);
}
