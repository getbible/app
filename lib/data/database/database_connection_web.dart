import 'dart:js_interop';

import 'package:drift/drift.dart';
import 'package:drift/wasm.dart';

import '../../core/errors.dart';

@JS('document.baseURI')
external String get _documentBaseUri;

// Friendly passage URLs can contain multiple path segments. Database assets
// belong to the deployment base, never to the current reader route.
Uri _databaseAsset(String name) => Uri.parse(_documentBaseUri).resolve(name);

Future<QueryExecutor> openDatabaseExecutor() async {
  final WasmDatabaseResult result = await WasmDatabase.open(
    databaseName: 'getbible_life',
    sqlite3Uri: _databaseAsset('sqlite3.wasm'),
    driftWorkerUri: _databaseAsset('drift_worker.dart.js'),
  );
  if (result.chosenImplementation == WasmStorageImplementation.inMemory) {
    await result.resolvedExecutor.close();
    throw const StorageException(
      'Browser storage is unavailable. Allow site storage and retry; private data cannot be saved in a temporary session.',
    );
  }
  return result.resolvedExecutor;
}

Future<QueryExecutor> openMemoryDatabaseExecutor() async {
  final WasmDatabaseResult result = await WasmDatabase.open(
    databaseName: 'getbible_life_test',
    sqlite3Uri: _databaseAsset('sqlite3.wasm'),
    driftWorkerUri: _databaseAsset('drift_worker.dart.js'),
  );
  return result.resolvedExecutor;
}
