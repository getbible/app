import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../core/request_cancellation.dart';
import '../domain/models/bible.dart';
import '../domain/models/passage.dart';
import '../domain/models/reference.dart';
import 'grouped_reference_lookup.dart';

/// Scripture displayed beside a saved coordinate, never written into a private
/// bookmark. The selected Bible owns the text, book name and text direction.
final class TopicVerseText {
  const TopicVerseText({required this.verse, required this.chapter});
  final Verse verse;
  final ReferenceChapter chapter;
  String get reference =>
      '${chapter.bookName} ${chapter.chapter}:${verse.verse}';
}

/// Loads only the revealed portion of a topic. Each verse has an independent
/// outcome so one unavailable coordinate does not hide the rest of the topic.
/// The shared lookup retains installed-first and HTTP-cache behavior. This small
/// memory cache avoids repeated work within the surface; it contains no private
/// quotations and cannot mix translations. Closing/replacing a topic invalidates
/// queued work and all late responses without closing the shared HTTP client.
final class TopicVerseLoader extends ChangeNotifier {
  TopicVerseLoader({
    required this.lookup,
    this.pageSize = 8,
    this.concurrency = 3,
    this.cacheLimit = 128,
  }) {
    if (pageSize < 1 ||
        pageSize > 32 ||
        concurrency < 1 ||
        concurrency > 4 ||
        cacheLimit < pageSize) {
      throw ArgumentError(
        'Use bounded topic page, concurrency and cache limits.',
      );
    }
  }

  final GroupedReferenceLookup lookup;
  final int pageSize, concurrency, cacheLimit;
  final RequestOwner _owner = RequestOwner();
  final LinkedHashMap<Passage, TopicVerseText> _cache = LinkedHashMap();
  final Map<Passage, TopicVerseText> _results = {};
  final Map<Passage, Object> _errors = {};
  final Set<Passage> _pending = {};
  List<Passage> _passages = const [];
  RequestCancellation? _token;
  int _visibleCount = 0;
  bool _loadingPage = false;

  int get visibleCount => _visibleCount;
  bool get hasMore => _visibleCount < _passages.length;
  bool get loadingPage => _loadingPage;
  TopicVerseText? textFor(Passage passage) => _results[passage];
  Object? errorFor(Passage passage) => _errors[passage];
  bool isLoading(Passage passage) => _pending.contains(passage);

  Future<void> open(Iterable<Passage> passages) async {
    final values = passages.toList(growable: false);
    for (final passage in values) {
      passage.validated();
      if (passage.chapter < 1 || passage.verse == null) {
        throw ArgumentError('Topic Scripture needs an exact verse.');
      }
    }
    _token = _owner.begin();
    _passages = values;
    _visibleCount = 0;
    _loadingPage = false;
    _results.clear();
    _errors.clear();
    _pending.clear();
    await loadMore();
  }

  Future<void> loadMore() async {
    final token = _token;
    if (token == null || !_owner.owns(token) || _loadingPage || !hasMore) {
      return;
    }
    final next = math.min(_visibleCount + pageSize, _passages.length);
    final batch = _passages.sublist(_visibleCount, next).toSet().toList();
    _visibleCount = next;
    _loadingPage = true;
    _pending.addAll(batch.where((passage) => !_results.containsKey(passage)));
    notifyListeners();
    var index = 0;
    Future<void> worker() async {
      while (_owner.owns(token) && index < batch.length) {
        await _load(batch[index++], token);
      }
    }

    await Future.wait(
      List.generate(math.min(concurrency, batch.length), (_) => worker()),
    );
    if (_owner.owns(token)) {
      _loadingPage = false;
      notifyListeners();
    }
  }

  Future<void> retry(Passage passage) async {
    final token = _token;
    // Retrying stays in the same bounded work queue: no extra parallel request
    // can be started while a page or another retry is in progress.
    if (token == null ||
        !_owner.owns(token) ||
        _loadingPage ||
        _pending.isNotEmpty ||
        !_passages.take(_visibleCount).contains(passage)) {
      return;
    }
    _pending.add(passage);
    _loadingPage = true;
    _errors.remove(passage);
    notifyListeners();
    await _load(passage, token);
    if (_owner.owns(token)) {
      _loadingPage = false;
      notifyListeners();
    }
  }

  Future<void> _load(Passage passage, RequestCancellation token) async {
    try {
      TopicVerseText? value = _cache.remove(passage);
      if (value == null) {
        final result = await token.bind(
          lookup.lookup(
            StructuredReferenceRequest(
              translation: passage.translation,
              selections: [ReferenceSelection.verse(passage)],
            ),
            cancellation: token,
          ),
        );
        if (!_owner.owns(token)) return;
        final chapter = result.chapters.single;
        value = TopicVerseText(verse: chapter.verses.single, chapter: chapter);
      }
      if (!_owner.owns(token)) return;
      _cache[passage] = value;
      while (_cache.length > cacheLimit) {
        _cache.remove(_cache.keys.first);
      }
      _results[passage] = value;
      _errors.remove(passage);
    } catch (error) {
      if (_owner.owns(token)) _errors[passage] = error;
    } finally {
      if (_owner.owns(token)) {
        _pending.remove(passage);
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _owner.cancel();
    _cache.clear();
    super.dispose();
  }
}
