import '../../core/request_cancellation.dart';
import '../models/offline_resource.dart';

/// Discovery and revision checks never download a complete resource. Application
/// policy decides when first use or an explicit refresh schedules installation.
abstract interface class OfflineResourceInstaller {
  Set<OfflineResourceKind> get supportedKinds;
  Uri get sourceUri;
  Future<OfflineResourceDescriptor> resolve(
    OfflineResourceKind kind,
    String id,
    RequestCancellation cancellation,
  );
  Future<OfflineResourceDescriptor> checkRevision(
    OfflineResourceDescriptor resource,
    RequestCancellation cancellation,
  );
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

/// A manual force check starts a new source snapshot rather than reusing a
/// short-lived batch shared by automatic checks of the same public catalogue.
abstract interface class OfflineRevisionCache {
  void clearRevisionCache();
}

/// Public-download bookkeeping is separate from private backups and content.
/// Only a successful source check advances checkedAt; retries retain that date.
abstract interface class OfflineFreshnessStore {
  Future<OfflineFreshness?> read(String resourceKey);
  Future<void> recordAttempt(
    String resourceKey,
    DateTime attemptedAt,
    DateTime retryAfter,
  );
  Future<void> recordSuccess(
    String resourceKey,
    String generation,
    DateTime checkedAt,
  );
  Future<void> recordCatalogueSuccess(String catalogueKey, DateTime checkedAt);
  Future<Set<String>> readExcludedKeys();
  Future<void> setExcluded(String resourceKey, bool excluded);
  Future<List<OfflineResourceDescriptor>> readAutomaticResources();
  Future<void> saveAutomaticResources(
    OfflineResourceKind kind,
    Uri sourceUri,
    List<OfflineResourceDescriptor> resources,
  );
  Future<void> remove(String resourceKey);

  /// Clears freshness only; catalogue plans and deliberate exclusions survive.
  Future<void> clear();
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
