import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

Future<QueryExecutor> openDatabaseExecutor() async {
  final Directory directory = await getApplicationSupportDirectory();
  final File file = File(
    '${directory.path}${Platform.pathSeparator}getbible.sqlite',
  );
  return NativeDatabase.createInBackground(file);
}

Future<QueryExecutor> openMemoryDatabaseExecutor() async =>
    NativeDatabase.memory();
