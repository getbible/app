import '../models/passage.dart';
import '../models/public_topic.dart';
import '../models/unified_bookmarks.dart';

abstract interface class UnifiedBookmarksRepository {
  Future<void> reconcile(
    List<BookmarkTopicMetadata> topics, {
    required String sourceScope,
    required String locale,
  });
  Future<void> download(
    List<PublicTopic> topics, {
    required List<BookmarkTopicMetadata> catalogue,
    required String sourceScope,
    required String locale,
    required String translation,
  });
  Future<void> removeGlobal({required String sourceScope, String? topicId});
  Future<void> removeMembership({
    required Passage passage,
    required int verse,
    required String groupId,
    int? start,
    int? end,
    required BookmarkOrigin origin,
  });
  Future<List<String>> recentGroups();
  Future<void> rememberGroup(String groupId);
}
