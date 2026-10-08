import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../../core/json.dart';
import '../../domain/models/annotations.dart';
import '../../domain/models/passage.dart';
import '../../domain/models/public_topic.dart';
import '../../domain/repositories/public_topics_repository.dart';
import '../database/local_database.dart';

/// Public association imports are explicit, additive and atomic. Provenance
/// lives in local settings, independently of the read-only resource cache.
final class SqlPublicTopicCopyRepository implements PublicTopicCopyRepository {
  SqlPublicTopicCopyRepository(
    this._database, {
    String Function()? createId,
    DateTime Function()? clock,
  }) : _createId = createId ?? const Uuid().v4,
       _clock = clock ?? (() => DateTime.now().toUtc());

  final LocalDatabase _database;
  final String Function() _createId;
  final DateTime Function() _clock;
  Future<void> _copyQueue = Future<void>.value();

  String _provenanceKey(String scope, String topicId) =>
      'topic-copy:v1:${Uri.encodeComponent(scopedPublicTopic(scope, topicId))}';

  @override
  Future<PublicTopicCopyPreview> preview({
    required PublicTopic topic,
    required String sourceScope,
    required String translation,
  }) async {
    final _CopyState state = await _readState(topic, sourceScope);
    return PublicTopicCopyPreview(
      topic: topic,
      sourceScope: sourceScope,
      translation: translation,
      groupName: state.group?.name ?? '${topic.name} (public topic copy)',
      existingGroupId: state.group?.id,
      alreadyPresent: topic.coordinates
          .where(
            (PublicTopicCoordinate item) =>
                state.coordinates.contains(item.key),
          )
          .length,
    );
  }

  @override
  Future<PublicTopicCopyResult> copy(PublicTopicCopyPreview preview) {
    // Serialize imports through this bounded adapter; the database also checks
    // collisions/provenance in its transaction, protecting independent writers.
    final Future<PublicTopicCopyResult> operation = _copyQueue.then(
      (_) => _copy(preview),
    );
    _copyQueue = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    return operation;
  }

  Future<PublicTopicCopyResult> _copy(PublicTopicCopyPreview preview) async {
    final PublicTopic topic = preview.topic;
    final _CopyState state = await _readState(topic, preview.sourceScope);
    final Set<String> occupied = <String>{
      ...state.groups.map((MarkingGroup group) => group.id),
      ...state.markings.map((Marking marking) => marking.id),
    };
    final String groupId =
        state.group?.id ?? _unusedId('private-topic-', occupied);
    final DateTime now = _clock();
    final MarkingGroup? newGroup = state.group == null
        ? MarkingGroup(
            id: groupId,
            name: preview.groupName,
            color: topic.color.toUpperCase(),
            sortOrder:
                state.groups.fold<int>(
                  0,
                  (int maximum, MarkingGroup group) =>
                      group.sortOrder > maximum ? group.sortOrder : maximum,
                ) +
                1,
            updatedAt: now,
          )
        : null;
    final List<Marking> markings = <Marking>[];
    for (final PublicTopicCoordinate coordinate in topic.coordinates) {
      if (state.coordinates.contains(coordinate.key)) continue;
      markings.add(
        Marking(
          id: _unusedId('private-topic-marking-', occupied),
          passage: Passage(
            translation: preview.translation,
            book: coordinate.book,
            chapter: coordinate.chapter,
          ).validated(),
          verse: coordinate.verse,
          start: null,
          end: null,
          quote: '',
          reference:
              'Book ${coordinate.book} ${coordinate.chapter}:${coordinate.verse}',
          groupId: groupId,
          createdAt: now,
        ),
      );
      if (markings.length % 256 == 0) {
        // Large public topics must not monopolize the native UI isolate.
        await Future<void>.delayed(Duration.zero);
      }
    }
    final int added = await _database.commitPublicTopicCopy(
      provenanceKey: _provenanceKey(preview.sourceScope, topic.id),
      groupId: groupId,
      newGroup: newGroup,
      newMarkings: markings,
    );
    return PublicTopicCopyResult(groupId: groupId, added: added);
  }

  String _unusedId(String prefix, Set<String> occupied) {
    for (int attempt = 0; attempt < 32; attempt++) {
      final String id = '$prefix${_createId()}';
      if (occupied.add(id)) return id;
    }
    throw StateError('Could not allocate a new private annotation identity.');
  }

  Future<_CopyState> _readState(PublicTopic topic, String scope) async {
    final String? raw = await _database.readSetting(
      _provenanceKey(scope, topic.id),
    );
    String? groupId;
    if (raw != null) {
      final JsonMap provenance = requireJsonMap(
        jsonDecode(raw),
        'public-topic copy provenance',
      );
      if (requireInt(provenance, 'version') != 1) {
        throw const FormatException(
          'Unsupported public-topic copy provenance.',
        );
      }
      groupId = requireString(provenance, 'groupId');
    }
    final List<MarkingGroup> groups = await _database.getGroups();
    final List<Marking> markings = await _database.getMarkings();
    final MarkingGroup? group = groups
        .where((MarkingGroup item) => item.id == groupId)
        .firstOrNull;
    return _CopyState(
      groups: groups,
      markings: markings,
      group: group,
      coordinates: group == null
          ? <String>{}
          : markings
                .where(
                  (Marking marking) =>
                      marking.groupId == group.id && marking.isWholeVerse,
                )
                .map(
                  (Marking marking) =>
                      '${marking.passage.canonicalKey}/${marking.verse}',
                )
                .toSet(),
    );
  }
}

final class _CopyState {
  const _CopyState({
    required this.groups,
    required this.markings,
    required this.group,
    required this.coordinates,
  });
  final List<MarkingGroup> groups;
  final List<Marking> markings;
  final MarkingGroup? group;
  final Set<String> coordinates;
}
