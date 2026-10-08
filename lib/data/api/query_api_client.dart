import '../../core/errors.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/reference.dart';
import 'api_configuration.dart';
import 'api_transport.dart';

final class QueryApiClient {
  const QueryApiClient({required this.transport});

  final ApiTransport transport;

  Future<ReferenceResult> query(
    String translation,
    String reference, {
    RequestCancellation? cancellation,
  }) async {
    final String selected = translation.toLowerCase();
    if (!RegExp(r'^[a-z0-9_-]+$').hasMatch(selected) ||
        reference.trim().isEmpty ||
        reference.runes.length > 512 ||
        reference.split(';').length > 8) {
      throw const FormatException(
        'The reference exceeds the Query request limits.',
      );
    }
    // Encode before path construction: slashes, ?, # and & are citation text,
    // never extra route segments or query parameters.
    final ApiResponse response = await transport.get(
      ApiService.query,
      '$selected/${Uri.encodeComponent(reference)}',
      cancellation: cancellation,
      maxBytes: ApiResponseLimits.query,
    );
    try {
      final ReferenceResult result = ReferenceResult.fromJson(
        response.json,
        translation: selected,
        reference: reference,
      );
      if (result.verseCount > 200) {
        throw const FormatException(
          'The Query response exceeds its verse limit.',
        );
      }
      return result;
    } on ApiFormatException {
      transport.discardResponse(response);
      rethrow;
    } on FormatException catch (error) {
      transport.discardResponse(response);
      throw ApiFormatException(
        'The reference service returned invalid Scripture.',
        error,
      );
    }
  }
}
