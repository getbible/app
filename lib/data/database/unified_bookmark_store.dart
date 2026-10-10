part of 'local_database.dart';

/// A catalog migration and membership import always observe the same private
/// snapshot. No notes, notebooks, journals, cache or installed resource rows are
/// replaced by this transaction.
extension UnifiedBookmarkStore on LocalDatabase {
  Future<void> reconcileBookmarks(
    List<BookmarkTopicMetadata> topics, {
    required String sourceScope,
    required String locale,
    List<PublicTopic> downloads = const [],
    String? translation,
  }) async {
    // Validate the complete explicit download before even beginning a write.
    final topicIds = topics.map((topic) => topic.id).toSet();
    for (final topic in topics) {
      if (!SharedBookmarkSource.isValidTopicId(topic.id) ||
          !RegExp(r'^#[a-fA-F0-9]{6}$').hasMatch(topic.summary.color) ||
          topic.summary.name.trim().isEmpty) {
        throw const FormatException('Invalid public bookmark metadata.');
      }
    }
    if (topicIds.length != topics.length || sourceScope.isEmpty) {
      throw const FormatException('Invalid public bookmark catalog.');
    }
    if (downloads.isNotEmpty) {
      Passage(translation: translation!, book: 1, chapter: 1).validated();
      for (final topic in downloads) {
        if (!topicIds.contains(topic.id) ||
            topic.coordinates.length > 100000 ||
            topic.coordinates.any(
              (c) =>
                  c.book < 1 ||
                  c.book > 66 ||
                  c.chapter < 1 ||
                  c.chapter > 150 ||
                  c.verse < 1 ||
                  c.verse > 2000,
            )) {
          throw const FormatException(
            'Invalid downloaded bookmark coordinates.',
          );
        }
      }
    }
    await _transaction((transaction) async {
      final existingGroups = (await transaction.runSelect(
        'SELECT * FROM marking_groups ORDER BY sort_order, name COLLATE NOCASE',
        [],
      )).map(_groupFromRow).toList();
      final existingMarks = (await transaction.runSelect(
        'SELECT * FROM markings ORDER BY created_at, id',
        [],
      )).map(_markingFromRow).toList();
      final now = DateTime.now().toUtc();
      // The baked-in legacy catalog is only a network-failure fallback on a
      // pristine installation. Replace it with actual API metadata before use.
      final defaults = starterMarkingGroups();
      final pristine =
          existingMarks.isEmpty &&
          existingGroups.length == defaults.length &&
          existingGroups.every(
            (group) => defaults.any(
              (item) => jsonEncode(item.toJson()) == jsonEncode(group.toJson()),
            ),
          );
      final plan = reconcileBookmarkGroups(
        groups: pristine ? [] : existingGroups,
        markings: existingMarks,
        topics: topics,
        sourceScope: sourceScope,
        locale: locale,
        now: now,
      );
      final byTopic = {
        for (final group in plan.groups)
          if (group.source?.effectiveScope == sourceScope)
            group.source!.topicId: group,
      };
      final groupRemaps = {...plan.groupIds};
      if (pristine) {
        // A selected fallback topic can predate the first successful catalog
        // read. Carry that choice into the corresponding API-created group.
        final fallback = reconcileBookmarkGroups(
          groups: existingGroups,
          markings: [],
          topics: topics,
          sourceScope: sourceScope,
          locale: locale,
          now: now,
        );
        final fallbackGroups = {
          for (final group in fallback.groups) group.id: group,
        };
        for (final entry in fallback.groupIds.entries) {
          final source = fallbackGroups[entry.value]?.source;
          final target = source?.effectiveScope == sourceScope
              ? byTopic[source?.topicId]
              : null;
          if (target != null) groupRemaps[entry.key] = target.id;
        }
      }
      final next = [...plan.markings];
      final occupiedIds = existingMarks.map((mark) => mark.id).toSet();
      final identities = {
        for (final mark in next)
          '${mark.sharedSource?.effectiveScope}|${mark.sharedSource?.topicId}|${mark.identity}',
      };
      for (final topic in downloads) {
        final group = byTopic[topic.id]!;
        for (final coordinate in topic.coordinates) {
          final base =
              'getbible-topic:${topic.id}:${coordinate.book}:${coordinate.chapter}:${coordinate.verse}';
          var id = base;
          var suffix = 1;
          while (occupiedIds.contains(id)) {
            id = '$base:${suffix++}';
          }
          final mark = Marking(
            id: id,
            passage: Passage(
              translation: translation!,
              book: coordinate.book,
              chapter: coordinate.chapter,
            ),
            verse: coordinate.verse,
            start: null,
            end: null,
            quote: '',
            reference:
                'Book ${coordinate.book} ${coordinate.chapter}:${coordinate.verse}',
            groupId: group.id,
            createdAt: now,
            source: SharedBookmarkSource(
              topicId: topic.id,
              sourceScope: sourceScope == SharedBookmarkSource.defaultScope
                  ? null
                  : sourceScope,
            ),
          );
          if (identities.add('$sourceScope|${topic.id}|${mark.identity}')) {
            occupiedIds.add(id);
            next.add(mark);
          }
        }
      }
      final existingGroupIds = existingGroups.map((group) => group.id).toSet();
      for (final group in plan.groups) {
        if (existingGroupIds.contains(group.id)) {
          await transaction.runCustom(
            'UPDATE marking_groups SET source_json = ? WHERE id = ?',
            [
              group.source == null ? null : jsonEncode(group.source!.toJson()),
              group.id,
            ],
          );
        } else {
          await _saveGroup(transaction, group);
        }
      }
      final nextIds = next.map((mark) => mark.id).toSet();
      for (final old in existingMarks) {
        if (!nextIds.contains(old.id)) {
          await transaction.runCustom('DELETE FROM markings WHERE id = ?', [
            old.id,
          ]);
        }
      }
      for (final mark in next) {
        await _saveMarking(transaction, mark);
      }
      final groupIds = plan.groups.map((group) => group.id).toSet();
      for (final old in existingGroups) {
        if (!groupIds.contains(old.id)) {
          await transaction.runCustom(
            'DELETE FROM marking_groups WHERE id = ?',
            [old.id],
          );
        }
      }
      final settings = await transaction.runSelect(
        'SELECT * FROM settings',
        [],
      );
      if (plan.groups.isNotEmpty &&
          !settings.any((row) => row['setting_key'] == 'readerPreferences')) {
        await transaction.runCustom(
          'INSERT INTO settings(setting_key,value,updated_at) VALUES(?,?,?)',
          [
            'readerPreferences',
            jsonEncode(
              ReaderPreferences(
                activeMarkingGroupId: plan.groups.first.id,
              ).toJson(),
            ),
            now.millisecondsSinceEpoch,
          ],
        );
      }
      for (final setting in settings) {
        final key = setting['setting_key']! as String;
        final original = setting['value']! as String;
        Object? value;
        if (key == 'readerPreferences') {
          final preference = ReaderPreferences.fromJson(jsonDecode(original));
          final remapped =
              groupRemaps[preference.activeMarkingGroupId] ??
              preference.activeMarkingGroupId;
          value = preference
              .copyWith(
                activeMarkingGroupId: groupIds.contains(remapped)
                    ? remapped
                    : plan.groups.firstOrNull?.id,
              )
              .toJson();
        } else if (key == 'bookmarks:v1:recent') {
          value = (jsonDecode(original) as List)
              .cast<String>()
              .map((id) => groupRemaps[id] ?? id)
              .where(groupIds.contains)
              .toSet()
              .take(6)
              .toList();
        } else if (key.startsWith('topic-copy:v1:') ||
            key.startsWith('topic-copy-alternate:v1:')) {
          final provenance = requireJsonMap(jsonDecode(original), 'topic copy');
          value = {
            ...provenance,
            'groupId':
                groupRemaps[provenance['groupId']] ?? provenance['groupId'],
          };
        }
        if (value != null && jsonEncode(value) != original) {
          // An automatic identity migration is not a new user preference edit.
          await transaction.runCustom(
            'UPDATE settings SET value = ? WHERE setting_key = ?',
            [jsonEncode(value), key],
          );
        }
      }
    });
  }

  Future<void> removeGlobalBookmarks({
    required String sourceScope,
    String? topicId,
  }) => _transaction((transaction) async {
    final rows = await transaction.runSelect(
      'SELECT * FROM markings WHERE start_offset IS NULL AND end_offset IS NULL',
      [],
    );
    for (final row in rows) {
      final mark = _markingFromRow(row);
      final source = mark.sharedSource;
      if (source?.effectiveScope == sourceScope &&
          (topicId == null || source?.topicId == topicId)) {
        await transaction.runCustom('DELETE FROM markings WHERE id = ?', [
          mark.id,
        ]);
      }
    }
  });

  Future<void> removeBookmarkMembership({
    required Passage passage,
    required int verse,
    required String groupId,
    int? start,
    int? end,
    required BookmarkOrigin origin,
  }) => _transaction((transaction) async {
    final rows = await transaction.runSelect(
      'SELECT * FROM markings WHERE group_id = ? AND book_nr = ? AND chapter_nr = ? AND verse_nr = ?',
      [groupId, passage.book, passage.chapter, verse],
    );
    for (final row in rows) {
      final mark = _markingFromRow(row);
      if (mark.matchesPassage(passage) &&
          mark.start == start &&
          mark.end == end &&
          mark.isSharedBookmark == (origin == BookmarkOrigin.global)) {
        await transaction.runCustom('DELETE FROM markings WHERE id = ?', [
          mark.id,
        ]);
      }
    }
  });

  Future<void> rememberBookmarkGroup(String groupId) => _transaction((
    transaction,
  ) async {
    if ((await transaction.runSelect(
      'SELECT id FROM marking_groups WHERE id = ?',
      [groupId],
    )).isEmpty) {
      return;
    }
    final saved = await transaction.runSelect(
      'SELECT value FROM settings WHERE setting_key = ?',
      ['bookmarks:v1:recent'],
    );
    final previous = saved.isEmpty
        ? <String>[]
        : (jsonDecode(saved.single['value']! as String) as List).cast<String>();
    final recent = <String>{groupId, ...previous}.take(6).toList();
    await transaction.runCustom(
      'INSERT INTO settings(setting_key,value,updated_at) VALUES(?,?,?) ON CONFLICT(setting_key) DO UPDATE SET value=excluded.value,updated_at=excluded.updated_at',
      [
        'bookmarks:v1:recent',
        jsonEncode(recent),
        DateTime.now().toUtc().millisecondsSinceEpoch,
      ],
    );
  });
}
