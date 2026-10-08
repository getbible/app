import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('all web locale packs are present and aligned', () {
    final Directory directory = Directory('assets/locales');
    final List<String> supported =
        (jsonDecode(File('${directory.path}/index.json').readAsStringSync())
                as List<Object?>)
            .cast<String>();

    expect(supported, hasLength(69));
    int? messageCount;
    for (final String locale in supported) {
      final File file = File('${directory.path}/$locale.json');
      expect(file.existsSync(), isTrue, reason: 'Missing locale $locale');
      final List<Object?> messages =
          jsonDecode(file.readAsStringSync()) as List<Object?>;
      expect(messages.every((Object? value) => value is String), isTrue);
      messageCount ??= messages.length;
      expect(
        messages,
        hasLength(messageCount),
        reason: 'Locale $locale is out of sync',
      );
    }
    expect(messageCount, greaterThan(0));
  });
}
