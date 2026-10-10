import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/topic_verse_loader.dart';

import 'support/topic_verse_fixture.dart';

void main() {
  test(
    'opening a large topic requests only eight verses with bounded concurrency',
    () async {
      final fixture = TopicVerseFixture()
        ..beforeResponse = (_) => Future<void>.delayed(Duration.zero);
      final loader = TopicVerseLoader(lookup: fixture.lookup);
      addTearDown(loader.dispose);
      final passages = fixture.passages(45);
      await loader.open(passages);
      expect(fixture.requests, passages.take(8));
      expect(fixture.peak, 3);
      expect(loader.visibleCount, 8);
      expect(loader.hasMore, isTrue);
      await loader.loadMore();
      expect(fixture.requests, passages.take(16));
      expect(loader.textFor(passages[15])!.verse.text, contains('verse 16.'));
      expect(loader.textFor(passages[16]), isNull);
    },
  );

  test(
    'one missing verse does not hide siblings and retry only fetches that row',
    () async {
      final fixture = TopicVerseFixture()..unavailable.add(2);
      final loader = TopicVerseLoader(lookup: fixture.lookup);
      addTearDown(loader.dispose);
      final passages = fixture.passages(3);
      await loader.open(passages);
      expect(loader.textFor(passages.first), isNotNull);
      expect(loader.errorFor(passages[1]), isNotNull);
      expect(loader.textFor(passages.last), isNotNull);
      fixture.unavailable.clear();
      await loader.retry(passages[1]);
      expect(fixture.requests, [...passages, passages[1]]);
      expect(loader.errorFor(passages[1]), isNull);
      expect(loader.textFor(passages[1])!.reference, 'John 8:2');
    },
  );

  test(
    'translation change cancels old queue and rejects late responses',
    () async {
      final fixture = TopicVerseFixture();
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.beforeResponse = (passage) async {
        if (passage.translation == 'kjv') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
      };
      final loader = TopicVerseLoader(lookup: fixture.lookup);
      addTearDown(loader.dispose);
      final oldPassages = fixture.passages(45);
      final old = loader.open(oldPassages);
      await entered.future;
      final current = fixture.passages(2, translation: 'other');
      await loader.open(current);
      await old;
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(
        fixture.requests.where((p) => p.translation == 'kjv').length,
        lessThanOrEqualTo(3),
      );
      expect(loader.visibleCount, 2);
      expect(loader.textFor(oldPassages.first), isNull);
      expect(loader.textFor(current.first)!.verse.text, startsWith('other'));
      expect(loader.loadingPage, isFalse);
    },
  );

  test(
    'reopening a cached topic is translation-specific and never fetches unrevealed rows',
    () async {
      final fixture = TopicVerseFixture();
      final loader = TopicVerseLoader(lookup: fixture.lookup);
      addTearDown(loader.dispose);
      await loader.open(fixture.passages(45));
      await loader.open(fixture.passages(45, translation: 'other'));
      await loader.open(fixture.passages(45));
      expect(fixture.requests.length, 16);
      expect(loader.visibleCount, 8);
      expect(
        loader.textFor(fixture.passages(1).single)!.verse.text,
        startsWith('kjv'),
      );
    },
  );

  test(
    'closing a loading topic drains cancellation without further queued work',
    () async {
      final fixture = TopicVerseFixture();
      final entered = Completer<void>();
      final release = Completer<void>();
      fixture.beforeResponse = (_) async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final loader = TopicVerseLoader(lookup: fixture.lookup);
      final opening = loader.open(fixture.passages(45));
      await entered.future;
      loader.dispose();
      await opening;
      release.complete();
      await Future<void>.delayed(Duration.zero);
      expect(fixture.requests.length, lessThanOrEqualTo(3));
    },
  );
}
