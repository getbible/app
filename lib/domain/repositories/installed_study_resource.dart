/// Optional capability exposed by installed/online Study adapters. Controllers
/// use it for honest provenance without depending on storage implementations.
abstract interface class InstalledStudyResource {
  Future<bool> isInstalled(String id);
}

/// A pinned read crossed an atomic installation/removal boundary. Controllers
/// may restart the complete metadata/index/content operation once; retrying
/// just the document would risk mixing revisions or stale entry identifiers.
final class InstalledStudyGenerationChanged implements Exception {
  const InstalledStudyGenerationChanged(this.resourceId);
  final String resourceId;
  @override
  String toString() =>
      'The installed Study resource changed. Retry this action.';
}
