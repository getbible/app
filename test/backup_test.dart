import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/domain/models/backup.dart';

void main() {
  test('rejects unsupported backup schemas', () {
    expect(
      () => BackupData.fromJson(<String, Object?>{'version': 99}),
      throwsFormatException,
    );
  });
}
