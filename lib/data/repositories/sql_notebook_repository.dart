import '../../domain/models/notebook.dart';
import '../../domain/repositories/notebook_repository.dart';
import '../database/local_database.dart';

final class SqlNotebookRepository implements NotebookRepository {
  const SqlNotebookRepository(this.database);
  final LocalDatabase database;
  @override
  Future<List<NotebookSummary>> notebooks() => database.getNotebooks();
  @override
  Future<Notebook?> notebook(String id) => database.getNotebook(id);
  @override
  Future<List<NotebookDraft>> drafts() => database.getNotebookDrafts();
  @override
  Future<void> saveDraft(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  }) => database.saveNotebookDraft(
    notebook,
    expectedRevision: expectedRevision,
    editorId: editorId,
  );
  @override
  Future<void> save(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  }) => database.saveNotebook(
    notebook,
    expectedRevision: expectedRevision,
    editorId: editorId,
  );
  @override
  Future<void> discardDraft(
    String id,
    int revision, {
    String editorId = 'primary',
  }) => database.discardNotebookDraft(id, revision, editorId: editorId);
  @override
  Future<void> delete(String id) => database.deleteNotebook(id);
  @override
  Future<String?> selectedNotebook() => database.selectedNotebook();
  @override
  Future<void> selectNotebook(String? id) => database.selectNotebook(id);
}
