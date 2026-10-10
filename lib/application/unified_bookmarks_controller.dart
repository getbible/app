import 'package:flutter/foundation.dart';

import '../core/request_cancellation.dart';
import '../domain/models/passage.dart';
import '../domain/models/public_topic.dart';
import '../domain/models/unified_bookmarks.dart';
import '../domain/repositories/public_topics_repository.dart';
import '../domain/repositories/unified_bookmarks_repository.dart';

/// Metadata reconciliation never adds global memberships. Only an explicit
/// download commits those memberships; removal is independently origin-scoped.
final class UnifiedBookmarksController extends ChangeNotifier {
  UnifiedBookmarksController({
    required this.storage,
    required this.publicTopics,
    required this.onChanged,
  });
  final UnifiedBookmarksRepository storage;
  final PublicTopicsRepository publicTopics;
  final Future<void> Function() onChanged;
  final RequestOwner _requests = RequestOwner();
  Future<void>? _operation;
  bool _closed = false;
  bool _disposed = false;
  bool loading = false;
  bool busy = false;
  Object? error;
  String? busyTopicId;
  List<String> recentGroupIds = const [];
  List<BookmarkTopicMetadata> catalogue = const [];
  String _locale = 'en';
  String? _checksum;
  final Set<Future<void>> _pendingWrites = {};

  BookmarkTopicMetadata? topic(String id) =>
      catalogue.where((topic) => topic.id == id).firstOrNull;

  Future<void> initialize({String locale = 'en'}) => _run(() async {
    loading = true;
    _locale = locale;
    _notify();
    recentGroupIds = await storage.recentGroups();
    final request = _requests.begin();
    final discovery = await publicTopics.discovery(cancellation: request);
    final summaries = await publicTopics.catalogue(cancellation: request);
    final locales = await publicTopics.locales(cancellation: request);
    if (summaries.topics.length != discovery.topicCount) {
      throw const FormatException(
        'The public topic catalog changed. Retry to load one revision.',
      );
    }
    final names = <String, Map<String, String>>{};
    // Only lightweight labels are loaded here, never public verse memberships.
    // Concurrency is bounded even when the service adds more name languages.
    for (var start = 0; start < locales.length; start += 4) {
      final batch = await Future.wait(
        locales
            .skip(start)
            .take(4)
            .map(
              (locale) =>
                  publicTopics.names(locale.code, cancellation: request),
            ),
      );
      for (final document in batch) {
        for (final entry in document.names.entries) {
          names.putIfAbsent(entry.key, () => {})[document.locale] = entry.value;
        }
      }
      request.throwIfCancelled();
    }
    final verified = await publicTopics.discovery(cancellation: request);
    if (verified.checksum != discovery.checksum) {
      throw const FormatException(
        'The public topic catalog changed. Retry to load one revision.',
      );
    }
    final next = summaries.topics
        .map(
          (summary) => BookmarkTopicMetadata(
            summary: summary,
            names: names[summary.id] ?? {},
          ),
        )
        .toList();
    request.throwIfCancelled();
    await storage.reconcile(
      next,
      sourceScope: publicTopics.sourceScope,
      locale: locale,
    );
    catalogue = List.unmodifiable(next);
    _checksum = verified.checksum;
    recentGroupIds = await storage.recentGroups();
    await onChanged();
  });

  Future<void> download({
    String? topicId,
    required String translation,
    String locale = 'en',
  }) async {
    if (catalogue.isEmpty) {
      await initialize(locale: locale);
      if (catalogue.isEmpty || error != null) return;
    }
    await _run(() async {
      busyTopicId = topicId;
      final request = _requests.begin();
      final before = await publicTopics.discovery(cancellation: request);
      if (_checksum != before.checksum) {
        throw const FormatException(
          'The public topic catalog changed. Reload topics before downloading.',
        );
      }
      final ids = topicId == null
          ? catalogue.map((topic) => topic.id).toList()
          : [topicId];
      if (ids.any((id) => topic(id) == null)) {
        throw const FormatException(
          'This public topic is no longer available. Reload topics.',
        );
      }
      final downloaded = <PublicTopic>[];
      var count = 0;
      for (var start = 0; start < ids.length; start += 4) {
        final batch = await Future.wait(
          ids
              .skip(start)
              .take(4)
              .map((id) => publicTopics.topic(id, cancellation: request)),
        );
        for (final item in batch) {
          count += item.coordinates.length;
          if (count > 100000) {
            throw const FormatException(
              'The public bookmark download exceeds the supported limit.',
            );
          }
          downloaded.add(item);
        }
        request.throwIfCancelled();
      }
      final after = await publicTopics.discovery(cancellation: request);
      if (before.checksum != after.checksum) {
        throw const FormatException(
          'Public bookmarks changed during download. Retry to keep one revision.',
        );
      }
      request.throwIfCancelled();
      await storage.download(
        downloaded,
        catalogue: catalogue,
        sourceScope: publicTopics.sourceScope,
        locale: _locale,
        translation: translation,
      );
      await onChanged();
    });
  }

  Future<void> removeGlobal({String? topicId}) => _run(() async {
    await storage.removeGlobal(
      sourceScope: publicTopics.sourceScope,
      topicId: topicId,
    );
    await onChanged();
  });

  Future<void> removeMembership({
    required Passage passage,
    required int verse,
    required String groupId,
    int? start,
    int? end,
    required BookmarkOrigin origin,
  }) => _run(() async {
    await storage.removeMembership(
      passage: passage,
      verse: verse,
      groupId: groupId,
      start: start,
      end: end,
      origin: origin,
    );
    await onChanged();
  });

  Future<void> rememberGroup(String groupId) {
    if (_closed) return Future<void>.value();
    late final Future<void> operation;
    operation =
        (() async {
              await storage.rememberGroup(groupId);
              if (_closed) return;
              recentGroupIds = await storage.recentGroups();
              _notify();
            })()
            .catchError((Object failure) {
              if (!_closed) {
                error = failure;
                _notify();
              }
            })
            .whenComplete(() => _pendingWrites.remove(operation));
    _pendingWrites.add(operation);
    return operation;
  }

  /// Imported reader data uses the same atomic migration when metadata is
  /// already available; unavailable public services never block private restore.
  Future<void> reload() async {
    await _operation;
    await _run(() async {
      if (catalogue.isNotEmpty) {
        await storage.reconcile(
          catalogue,
          sourceScope: publicTopics.sourceScope,
          locale: _locale,
        );
      }
      recentGroupIds = await storage.recentGroups();
      await onChanged();
    });
  }

  Future<void> _run(Future<void> Function() action) {
    if (_closed || busy) return _operation ?? Future<void>.value();
    busy = true;
    error = null;
    _notify();
    final operation = action()
        .catchError((Object failure) {
          if (!_closed) error = failure;
        })
        .whenComplete(() {
          loading = false;
          busy = false;
          busyTopicId = null;
          _operation = null;
          _notify();
        });
    _operation = operation;
    return operation;
  }

  Future<void> close() async {
    _closed = true;
    _requests.cancel();
    await _operation;
    await Future.wait(_pendingWrites.toList());
  }

  void resume() {
    if (!_disposed) _closed = false;
  }

  void _notify() {
    if (!_closed && !_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _closed = true;
    _disposed = true;
    _requests.cancel();
    super.dispose();
  }
}
