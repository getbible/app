import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/domain/models/passage.dart';

void main() {
  test('parses canonical passage links', () {
    final PassageLink? link = parsePassageLink(
      Uri.parse('https://app.getbible.life/KJV/Ephesians/5?verse=2'),
    );
    expect(link?.translation, 'kjv');
    expect(link?.bookSlug, 'Ephesians');
    expect(link?.chapter, 5);
    expect(link?.verse, 2);
  });
}
