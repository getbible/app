import 'dart:convert';

import '../../domain/models/passage.dart';
import '../../domain/models/public_topic.dart';
import '../../domain/models/unified_bookmarks.dart';
import '../../domain/repositories/unified_bookmarks_repository.dart';
import '../database/local_database.dart';

final class SqlUnifiedBookmarksRepository
    implements UnifiedBookmarksRepository {
  const SqlUnifiedBookmarksRepository(this.database);
  final LocalDatabase database;
  @override
  Future<void> reconcile(
    List<BookmarkTopicMetadata> topics, {
    required String sourceScope,
    required String locale,
  }) => database.reconcileBookmarks(
    topics,
    sourceScope: sourceScope,
    locale: locale,
  );
  @override
  Future<void> download(
    List<PublicTopic> topics, {
    required List<BookmarkTopicMetadata> catalogue,
    required String sourceScope,
    required String locale,
    required String translation,
  }) => database.reconcileBookmarks(
    catalogue,
    sourceScope: sourceScope,
    locale: locale,
    downloads: topics,
    translation: translation,
  );
  @override
  Future<void> removeGlobal({required String sourceScope, String? topicId}) =>
      database.removeGlobalBookmarks(
        sourceScope: sourceScope,
        topicId: topicId,
      );
  @override
  Future<void> removeMembership({
    required Passage passage,
    required int verse,
    required String groupId,
    int? start,
    int? end,
    required BookmarkOrigin origin,
  }) => database.removeBookmarkMembership(
    passage: passage,
    verse: verse,
    groupId: groupId,
    start: start,
    end: end,
    origin: origin,
  );
  @override
  Future<void> rememberGroup(String groupId) =>
      database.rememberBookmarkGroup(groupId);
  @override
  Future<List<String>> recentGroups() async {
    final value = await database.readSetting('bookmarks:v1:recent');
    return value == null
        ? []
        : (jsonDecode(value) as List).cast<String>().take(6).toList();
  }
}
