import '../../core/errors.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/commentary.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/repositories/commentary_repository.dart';
import '../api/api_configuration.dart';
import '../api/api_transport.dart';
import '../api/commentary_adapter.dart';
import '../api/service_envelope_adapters.dart';

/// Online browsing reads only discovery, metadata, coverage and one chapter.
/// Whole-book/module downloads belong to explicit offline installation later.
final class ApiCommentaryRepository implements CommentaryRepository {
  const ApiCommentaryRepository(this.transport);
  final ApiTransport transport;

  @override
  Future<CommentaryCatalogue> catalogue({RequestCancellation? cancellation}) =>
      _read(
        '/v1/commentaries.json',
        ServiceEnvelopeAdapters.commentaries,
        cancellation,
      );

  @override
  Future<CommentaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) {
    return _read(
      '/v1/${_segment(module)}/metadata.json',
      (Object? value) => CommentaryAdapter.metadata(value, module),
      cancellation,
    );
  }

  @override
  Future<CommentaryCoverage> coverage(
    String module, {
    RequestCancellation? cancellation,
  }) {
    return _read(
      '/v1/${_segment(module)}/books.json',
      (Object? value) => CommentaryAdapter.coverage(value, module),
      cancellation,
    );
  }

  @override
  Future<CommentaryChapter> chapter(
    String module,
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  }) {
    if (book < 1 || book > 83 || chapter < 0) {
      throw const FormatException('Select a published commentary chapter.');
    }
    return _read(
      '/v1/${_segment(module)}/$book/$chapter.json',
      (Object? value) =>
          CommentaryAdapter.chapter(value, module, book, chapter),
      cancellation,
    );
  }

  Future<T> _read<T>(
    String path,
    T Function(Object?) parse,
    RequestCancellation? cancellation,
  ) async {
    final ApiResponse response = await transport.get(
      ApiService.commentaries,
      path,
      maxBytes: ApiResponseLimits.chapter,
      cancellation: cancellation,
    );
    try {
      return parse(response.json);
    } on FormatException catch (error) {
      transport.discardResponse(response);
      throw ApiFormatException('The commentary resource is invalid.', error);
    } on ApiFormatException {
      transport.discardResponse(response);
      rethrow;
    }
  }
}

String _segment(String module) {
  if (module.isEmpty ||
      module == '.' ||
      module == '..' ||
      module.contains('/') ||
      module.contains('\\')) {
    throw const FormatException('Invalid commentary module identity.');
  }
  return Uri.encodeComponent(module);
}
