import '../../core/request_cancellation.dart';
import '../models/reference.dart';

abstract interface class QueryRepository {
  Future<ReferenceResult> query(
    String translation,
    String reference, {
    RequestCancellation? cancellation,
  });
}
