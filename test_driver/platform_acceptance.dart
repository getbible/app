import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

Future<void> main() async {
  final output = Directory('build/runtime-evidence');
  await output.create(recursive: true);
  await integrationDriver(
    writeResponseOnFailure: true,
    onScreenshot: (name, bytes, [arguments]) async {
      final safeName = name.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
      await File('${output.path}/$safeName.png').writeAsBytes(bytes);
      return true;
    },
    responseDataCallback: (data) async {
      await File(
        '${output.path}/results.json',
      ).writeAsString(const JsonEncoder.withIndent('  ').convert(data));
    },
  );
}
