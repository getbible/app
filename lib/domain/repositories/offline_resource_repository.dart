import '../../core/request_cancellation.dart';
import '../models/offline_resource.dart';

/// Installation is always an explicit user action. Discovery must only request
/// small catalogues, never a whole Bible or Study module.
abstract interface class OfflineResourceInstaller {
  Set<OfflineResourceKind> get supportedKinds;
  Future<List<OfflineResourceDescriptor>> discover(
    RequestCancellation cancellation,
  );

  /// Return only after every required document and source hash has validated.
  /// The manager makes all writes visible together after this future succeeds.
  Future<void> install(
    OfflineResourceDescriptor resource,
    OfflineInstallSink sink,
    RequestCancellation cancellation,
  );
}

abstract interface class OfflineInstallSink {
  Future<void> setVerifiedDescriptor(OfflineResourceDescriptor resource);

  /// Document paths are installer-owned logical keys, not filesystem paths.
  Future<void> writeDocument(
    String path,
    String rawJson, {
    String? sha256,
    String? sha1,
  });

  /// At most 32 independently validated documents, 8 MiB total UTF-8.
  Future<void> writeDocuments(Map<String, String> documents);
  Future<void> writeSearchVerses(List<OfflineSearchVerse> verses);
  void progress(int completed, int? total, String label);
}

abstract interface class OfflineResourceStore {
  Future<List<OfflineInstalledResource>> listInstalled();
  Future<OfflineInstalledResource?> find(
    OfflineResourceKind kind,
    String id,
    Uri sourceUri,
  );
  Future<String?> readDocument(
    String resourceKey,
    String path, {
    String? generation,
  });
  Future<List<String>> listDocumentPaths(
    String resourceKey, {
    String prefix = '',
    int offset = 0,
    int limit = 100,
    String? generation,
  });

  /// Bounded candidate scan; exact-word/proximity semantics belong to the
  /// Bible repository. Terms are literal substrings, never SQL wildcards.
  Future<List<OfflineSearchVerse>> readSearchVerses(
    String resourceKey, {
    List<String> terms = const [],
    List<int>? books,
    bool matchAny = false,
    bool caseSensitive = false,
    int offset = 0,
    int limit = 100,
    String? generation,
  });
  Future<List<OfflineInstallAttempt>> listAttempts();
  Future<int> usedBytes();
  Future<void> begin(
    OfflineResourceDescriptor resource,
    String generation, {
    required int quotaBytes,
  });
  Future<int> writeDocument(
    String generation,
    String path,
    String rawJson, {
    required int quotaBytes,
  });
  Future<int> writeDocuments(
    String generation,
    Map<String, String> documents, {
    required int quotaBytes,
  });
  Future<int> writeSearchVerses(
    String generation,
    List<OfflineSearchVerse> verses, {
    required int quotaBytes,
  });
  Future<void> updateDescriptor(
    String generation,
    OfflineResourceDescriptor resource,
  );
  Future<void> heartbeat(String generation);
  Future<void> activate(String generation);
  Future<void> abandon(
    String generation,
    OfflineAttemptState state,
    String message,
  );
  Future<void> recoverInterrupted();
  Future<void> remove(String resourceKey);
}
