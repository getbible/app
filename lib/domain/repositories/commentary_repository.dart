import '../../core/request_cancellation.dart';
import '../models/commentary.dart';
import '../models/service_envelopes.dart';

abstract interface class CommentaryRepository {
  Future<CommentaryCatalogue> catalogue({RequestCancellation? cancellation});
  Future<CommentaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  });
  Future<CommentaryCoverage> coverage(
    String module, {
    RequestCancellation? cancellation,
  });
  Future<CommentaryChapter> chapter(
    String module,
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  });
}
