import '../models/notebook.dart';

abstract interface class NotebookRepository {
  Future<List<NotebookSummary>> notebooks();
  Future<Notebook?> notebook(String id);
  Future<List<NotebookDraft>> drafts();
  Future<void> saveDraft(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  });

  /// Atomically saves the document and blocks, and removes the matching draft.
  /// A stale expected revision fails rather than overwriting a newer document.
  Future<void> save(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  });
  Future<void> discardDraft(
    String id,
    int revision, {
    String editorId = 'primary',
  });
  Future<void> delete(String id);
  Future<String?> selectedNotebook();
  Future<void> selectNotebook(String? id);
}
