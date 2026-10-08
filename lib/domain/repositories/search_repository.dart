import '../../core/request_cancellation.dart';
import '../models/online_search.dart';

abstract interface class SearchRepository {
  Future<OnlineSearchPage> search(
    OnlineSearchRequest request, {
    RequestCancellation? cancellation,
  });
}
