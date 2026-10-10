import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/offline/bible_index_worker.dart';

/// A reproducible synthetic corpus exercises the actual native worker. Timing
/// and memory are evidence, not flaky device-speed acceptance thresholds.
void workerPerformanceJourney({
  required void Function(Map<String, Object?>) record,
}) {
  testWidgets(
    'large corpus is indexed off the UI isolate in bounded batches',
    (tester) async {
      await tester.runAsync(() async {
        const books = 20;
        const chapters = 20;
        const verses = 50;
        final bytes = utf8.encode(
          jsonEncode({
            'abbreviation': 'perf',
            'translation': 'Synthetic worker acceptance corpus',
            'language': 'English',
            'lang': 'en',
            'direction': 'LTR',
            'books': [
              for (var book = 1; book <= books; book++)
                {
                  'nr': book,
                  'name': 'Fixture $book',
                  'chapters': [
                    for (var chapter = 1; chapter <= chapters; chapter++)
                      {
                        'chapter': chapter,
                        'name': 'Fixture $book $chapter',
                        'verses': [
                          for (var verse = 1; verse <= verses; verse++)
                            {
                              'chapter': chapter,
                              'verse': verse,
                              'text':
                                  'Original synthetic Scripture $book:$chapter:$verse. '
                                      'Unicode keeps שלום, λόγος, and 😀 intact. ' *
                                  3,
                            },
                        ],
                      },
                  ],
                },
            ],
          }),
        );
        var rows = 0;
        var batches = 0;
        var heartbeat = 0;
        var maximumBatch = 0;
        final watch = Stopwatch()..start();
        final timer = Timer.periodic(const Duration(milliseconds: 10), (_) {
          heartbeat++;
        });
        try {
          await indexBibleInWorker(
            bytes,
            'perf',
            sha1.convert(bytes).toString(),
            (batch) async {
              batches++;
              if (batch['verses'] case final List<Object?> values) {
                rows += values.length;
                if (values.length > maximumBatch) maximumBatch = values.length;
                expect(values.length, lessThanOrEqualTo(100));
              }
            },
            RequestCancellation(),
          );
        } finally {
          timer.cancel();
          watch.stop();
        }
        expect(rows, books * chapters * verses);
        expect(
          heartbeat,
          greaterThan(0),
          reason: 'The UI event loop must run while parsing.',
        );
        record({
          'corpus': 'synthetic-v1',
          'sourceBytes': bytes.length,
          'verses': rows,
          'workerBatches': batches,
          'maximumVerseBatch': maximumBatch,
          'elapsedMilliseconds': watch.elapsedMilliseconds,
          'uiHeartbeatTicks': heartbeat,
          'processRssBytes': ProcessInfo.currentRss,
          'processPeakRssBytes': ProcessInfo.maxRss,
          'platform': Platform.operatingSystem,
        });
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
