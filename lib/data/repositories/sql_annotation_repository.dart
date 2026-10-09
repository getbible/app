import '../../domain/models/annotations.dart';
import '../../domain/models/backup.dart';
import '../../domain/models/passage.dart';
import '../../domain/repositories/annotation_repository.dart';
import '../database/local_database.dart';

final class SqlAnnotationRepository implements AnnotationRepository {
  const SqlAnnotationRepository(this._database);

  final LocalDatabase _database;

  @override
  Future<List<MarkingGroup>> getGroups() => _database.getGroups();

  @override
  Future<List<Marking>> getMarkings() => _database.getMarkings();

  @override
  Future<List<Marking>> getMarkingsForPassage(Passage passage) =>
      _database.getMarkings(passage: passage);

  @override
  Future<List<VerseNote>> getNotes() => _database.getNotes();

  @override
  Future<List<VerseNote>> getNotesForPassage(Passage passage) =>
      _database.getNotes(passage: passage);

  @override
  Future<void> saveGroup(MarkingGroup group) => _database.saveGroup(group);

  @override
  Future<void> deleteGroup(String groupId) => _database.deleteGroup(groupId);

  @override
  Future<void> saveMarking(Marking marking) => _database.saveMarking(marking);

  @override
  Future<void> addMarkingMemberships(List<Marking> markings) =>
      _database.addMarkingMemberships(markings);

  @override
  Future<void> replaceMarkings(List<Marking> remove, List<Marking> add) =>
      _database.replaceMarkings(remove, add);

  @override
  Future<void> deleteMarking(String id) => _database.deleteMarking(id);

  @override
  Future<void> deleteAllMarkings() => _database.deleteAllMarkings();

  @override
  Future<void> saveNote(VerseNote note) => _database.saveNote(note);

  @override
  Future<void> deleteNote(String canonicalKey) =>
      _database.deleteNote(canonicalKey);

  @override
  Future<void> replaceAll(BackupData backup) => _database.replaceReaderData(
    groups: backup.groups,
    markings: backup.markings,
    notes: backup.notes,
  );

  @override
  Future<void> clearAllReaderData() => _database.clearAllReaderData();
}
