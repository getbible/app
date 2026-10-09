import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/domain/models/cache.dart';
import 'package:getbible_live/services/daily_scripture_service.dart';

void main() {
  test('parses website daily aliases and deliberately opens KJV', () {
    final daily = parseDailyScripture(<String, Object?>{
      'date': 'Monday 20-July, 2026',
      'getbible': 'https://getbible.life/KJV/Ephesians/5/2',
      'name': 'Ephesians 5:2',
      'scripture': <Object?>[
        <String, Object?>{'nr': 2, 'text': 'Test'},
      ],
    }, DateTime.utc(2026, 7, 20));

    expect(daily.translation, 'kjv');
    expect(daily.bookName, 'Ephesians');
    expect(daily.chapter, 5);
    expect(daily.verse, 2);
    expect(daily.isCurrent(DateTime(2026, 7, 20)), isTrue);
  });

  test(
    'retains deduplicated ranges and excludes explicitly different chapters',
    () {
      final daily = parseDailyScripture(<String, Object?>{
        'date': '2026-10-09',
        'reference': 'John 3:16 – 18, 20; 4:1, 2',
        'verses': <String>['3:16', '3:22', '4:2'],
        'scripture': <Object?>[
          null,
          'invalid row',
          <String, Object?>{'nr': 21, 'chapter': 3},
          <String, Object?>{'nr': 19, 'chapter': 4},
          <String, Object?>{'nr': '-3'},
        ],
      }, DateTime.utc(2026, 10, 9));
      expect(daily.verse, 16);
      expect(daily.verses, <int>[16, 17, 18, 20, 21, 22]);
      expect(DailyScriptureCache.fromJson(daily.toJson()).verses, daily.verses);
      expect(() => daily.verses.add(23), throwsUnsupportedError);
    },
  );

  test('preserves all scripture rows after the first linked verse', () {
    final daily = parseDailyScripture(<String, Object?>{
      'date': '2026-10-09',
      'getbible': 'https://getbible.life/KJV/Revelation/1/9',
      'scripture': <Object?>[
        for (final int nr in <int>[9, 10, 12, 9]) <String, Object?>{'nr': nr},
      ],
    }, DateTime.utc(2026, 10, 9));
    expect(daily.bookName, 'Revelation');
    expect(daily.chapter, 1);
    expect(daily.verses, <int>[9, 10, 12]);
  });

  test('rejects a malformed or unbounded verse selection', () {
    for (final String verses in <String>['-3', '0', '1-999999999', '4-2']) {
      expect(
        () => parseDailyScripture(<String, Object?>{
          'date': '2026-10-09',
          'book': 'John',
          'chapter': 3,
          'verses': verses,
        }, DateTime.utc(2026, 10, 9)),
        throwsFormatException,
      );
    }
  });

  test('a valid anchor cannot hide an invalid same-chapter range', () {
    for (final String range in <String>['16-999999999', '20-16', '0-2']) {
      expect(
        () => parseDailyScripture(<String, Object?>{
          'date': '2026-10-09',
          'book': 'John',
          'chapter': 3,
          'verse': 16,
          'verses': range,
        }, DateTime.utc(2026, 10, 9)),
        throwsFormatException,
      );
    }
    final daily = parseDailyScripture(<String, Object?>{
      'date': '2026-10-09',
      'book': 'John',
      'chapter': 3,
      'verse': 16,
      'verses': '4:1-999999999',
    }, DateTime.utc(2026, 10, 9));
    expect(daily.verses, <int>[16]);
  });

  test(
    'legacy caches remain readable but cannot claim a complete selection',
    () {
      final daily = DailyScriptureCache.fromJson(<String, Object?>{
        'version': 1,
        'date': '2026-10-09',
        'bookName': 'John',
        'chapter': 3,
        'verse': 16,
        'cachedAt': DateTime.utc(2026, 10, 9).millisecondsSinceEpoch,
      });
      expect(daily.verses, <int>[16]);
      expect(daily.hasCompleteSelection, isFalse);
    },
  );
}
