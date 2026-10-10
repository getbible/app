import 'package:flutter/foundation.dart' show ValueChanged;

import '../core/errors.dart';
import '../data/api/api_configuration.dart';
import '../data/api/api_transport.dart';
import '../data/database/local_database.dart';
import '../data/repositories/api_commentary_repository.dart';
import '../data/repositories/api_dictionary_repository.dart';
import '../data/repositories/api_public_topics_repository.dart';
import '../data/repositories/installed_study_repositories.dart';
import '../data/repositories/sql_notebook_repository.dart';
import '../data/repositories/sql_public_topic_copy_repository.dart';
import '../data/repositories/sql_study_preferences_repository.dart';
import '../domain/models/offline_resource.dart';
import '../domain/repositories/notebook_repository.dart';
import '../domain/repositories/offline_resource_repository.dart';
import 'commentary_controller.dart';
import 'dictionary_controller.dart';
import 'notebook_controller.dart';
import 'topics_controller.dart';

/// The app's composition boundary shares one public HTTP adapter while keeping
/// private persistence and each Study interaction independently owned.
final class StudyServices {
  StudyServices({
    required LocalDatabase database,
    required ApiTransport transport,
    NotebookRepository? notebookRepository,
    OfflineResourceStore? offlineStore,
    ValueChanged<String> Function(OfflineResourceKind kind)? captureResourceUse,
  }) {
    final SqlStudyPreferencesRepository preferences =
        SqlStudyPreferencesRepository(database);
    dictionary = DictionaryController(
      repository: offlineStore == null
          ? ApiDictionaryRepository(transport)
          : InstalledDictionaryRepository(
              store: offlineStore,
              sourceUri: transport.configuration
                  .endpoint(ApiService.dictionaries)
                  .baseUri,
              online: ApiDictionaryRepository(transport),
            ),
      preferences: preferences,
      captureResourceUse: captureResourceUse == null
          ? null
          : () => captureResourceUse(OfflineResourceKind.dictionary),
    );
    commentary = CommentaryController(
      repository: offlineStore == null
          ? ApiCommentaryRepository(transport)
          : InstalledCommentaryRepository(
              store: offlineStore,
              sourceUri: transport.configuration
                  .endpoint(ApiService.commentaries)
                  .baseUri,
              online: ApiCommentaryRepository(transport),
            ),
      preferences: preferences,
      captureResourceUse: captureResourceUse == null
          ? null
          : () => captureResourceUse(OfflineResourceKind.commentary),
    );
    topics = TopicsController(
      repository: offlineStore == null
          ? ApiPublicTopicsRepository(transport)
          : InstalledPublicTopicsRepository(
              store: offlineStore,
              sourceUri: transport.configuration
                  .endpoint(ApiService.bookmarks)
                  .baseUri,
              online: ApiPublicTopicsRepository(transport),
            ),
      preferences: preferences,
      copyRepository: SqlPublicTopicCopyRepository(database),
    );
    notebooks = NotebookController(
      notebookRepository ?? SqlNotebookRepository(database),
    );
  }

  late final DictionaryController dictionary;
  late final CommentaryController commentary;
  late final TopicsController topics;
  late final NotebookController notebooks;
  Future<void>? _closeFuture;

  /// Reopen Study against newly imported private preferences. Notebook reload
  /// remains owned by the portability transaction and notebook controller.
  void reloadImportedPreferences() {
    commentary.clearRememberedPreferences();
    dismissResources();
  }

  Future<void> refreshInstallationStatus() async {
    await Future.wait<void>([
      dictionary.refreshInstallationStatus(),
      commentary.refreshInstallationStatus(),
      topics.refreshInstallationStatus(),
    ]);
  }

  void dismissResources() {
    dictionary.close();
    commentary.close();
    topics.dismiss();
  }

  /// Await private writes before the owning application closes SQLite.
  Future<void> close() =>
      _closeFuture ??= _close().catchError((Object error, StackTrace stack) {
        _closeFuture = null;
        Error.throwWithStackTrace(error, stack);
      });

  Future<void> _close() async {
    dismissResources();
    await notebooks.flush();
    if (notebooks.hasUndurableDrafts) {
      throw const StorageException(
        'The latest notebook edits could not be saved. Retry saving before closing.',
      );
    }
    dictionary.dispose();
    commentary.dispose();
    topics.dispose();
    notebooks.dispose();
  }
}
