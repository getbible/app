import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../core/errors.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/dictionary.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/repositories/dictionary_repository.dart';
import '../api/api_configuration.dart';
import '../api/api_transport.dart';
import '../api/dictionary_adapters.dart';
import '../api/service_envelope_adapters.dart';

/// Online reads are deliberately limited to discovery, index and chosen entry.
/// Whole-module installation has a separate, explicit later lifecycle.
final class ApiDictionaryRepository implements DictionaryRepository {
  const ApiDictionaryRepository(this.transport);
  final ApiTransport transport;

  @override
  Future<DictionaryCatalogue> catalogue({RequestCancellation? cancellation}) =>
      _read(
        '/v1/dictionaries.json',
        ServiceEnvelopeAdapters.dictionaries,
        cancellation,
      );
  @override
  Future<DictionaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) => _read(
    '/v1/${_segment(module)}/metadata.json',
    (Object? value) => DictionaryAdapters.metadata(value, module),
    cancellation,
  );
  @override
  Future<DictionaryIndex> index(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    final ApiResponse response = await transport.get(
      ApiService.dictionaries,
      '/v1/${_segment(module)}/index.json',
      maxBytes: ApiResponseLimits.chapter,
      cancellation: cancellation,
    );
    try {
      final _DictionaryIndexInput input = _DictionaryIndexInput(response.bytes, module);
      // Tiny indexes do not justify isolate setup; large published dictionaries
      // build their normalized search keys away from the native UI isolate.
      final Future<DictionaryIndex> parsing = response.bytes.length < 256 * 1024
          ? Future<DictionaryIndex>.value(_parseIndex(input))
          : compute(_parseIndex, input);
      return await (cancellation == null
          ? parsing
          : cancellation.bind(parsing));
    } on FormatException catch (error) {
      transport.discardResponse(response);
      throw ApiFormatException('The dictionary index is invalid.', error);
    } on ApiFormatException {
      transport.discardResponse(response);
      rethrow;
    }
  }

  @override
  Future<DictionaryEntry> entry(
    String module,
    String id, {
    RequestCancellation? cancellation,
  }) => _read(
    '/v1/${_segment(module)}/${_segment(id)}.json',
    (Object? value) => DictionaryAdapters.entry(value, module, id),
    cancellation,
  );

  Future<T> _read<T>(
    String path,
    T Function(Object?) parse,
    RequestCancellation? cancellation,
  ) async {
    final ApiResponse response = await transport.get(
      ApiService.dictionaries,
      path,
      maxBytes: ApiResponseLimits.chapter,
      cancellation: cancellation,
    );
    try {
      return parse(response.json);
    } on FormatException catch (error) {
      transport.discardResponse(response);
      throw ApiFormatException('The dictionary document is invalid.', error);
    } on ApiFormatException {
      transport.discardResponse(response);
      rethrow;
    }
  }
}

final class _DictionaryIndexInput {
  const _DictionaryIndexInput(this.bytes, this.module);
  final List<int> bytes;
  final String module;
}

DictionaryIndex _parseIndex(_DictionaryIndexInput input) =>
    DictionaryAdapters.index(
      jsonDecode(utf8.decode(input.bytes, allowMalformed: false)),
      input.module,
    );

String _segment(String value) {
  if (value.isEmpty ||
      value == '.' ||
      value == '..' ||
      value.contains('/') ||
      value.contains('\\')) {
    throw const FormatException('Invalid dictionary document identifier.');
  }
  return Uri.encodeComponent(value);
}
