import '../models/annotations.dart';
import '../models/backup.dart';
import '../models/passage.dart';

abstract interface class AnnotationRepository {
  Future<List<MarkingGroup>> getGroups();
  Future<List<Marking>> getMarkings();
  Future<List<Marking>> getMarkingsForPassage(Passage passage);
  Future<List<VerseNote>> getNotes();
  Future<List<VerseNote>> getNotesForPassage(Passage passage);
  Future<void> saveGroup(MarkingGroup group);
  Future<void> deleteGroup(String groupId);
  Future<void> saveMarking(Marking marking);

  /// Adds only missing semantic memberships in one atomic operation. Existing
  /// quotes and independent shared/personal origins are never overwritten.
  Future<void> addMarkingMemberships(List<Marking> markings);
  Future<void> replaceMarkings(List<Marking> remove, List<Marking> add);
  Future<void> deleteMarking(String id);
  Future<void> deleteAllMarkings();
  Future<void> saveNote(VerseNote note);
  Future<void> deleteNote(String canonicalKey);
  Future<void> replaceAll(BackupData backup);
  Future<void> clearAllReaderData();
}
