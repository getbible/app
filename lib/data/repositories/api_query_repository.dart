import '../../core/request_cancellation.dart';
import '../../domain/models/reference.dart';
import '../../domain/repositories/query_repository.dart';
import '../api/query_api_client.dart';

final class ApiQueryRepository implements QueryRepository {
  const ApiQueryRepository(this.api);

  final QueryApiClient api;

  @override
  Future<ReferenceResult> query(
    String translation,
    String reference, {
    RequestCancellation? cancellation,
  }) => api.query(translation, reference, cancellation: cancellation);
}
