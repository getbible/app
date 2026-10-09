/// Optional capability exposed by installed/online Study adapters. Controllers
/// use it for honest provenance without depending on storage implementations.
abstract interface class InstalledStudyResource {
  Future<bool> isInstalled(String id);
}
