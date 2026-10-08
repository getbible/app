import '../../core/request_cancellation.dart';
import '../models/service_envelopes.dart';

/// Discovery boundary only. Entry lookup, study panels and explicit offline
/// installations are introduced by their own complete user workflows.
abstract interface class StudyResourcesRepository {
  Future<DictionaryCatalogue> getDictionaries({
    RequestCancellation? cancellation,
  });
  Future<CommentaryCatalogue> getCommentaries({
    RequestCancellation? cancellation,
  });
  Future<PublicTopicCatalogue> getPublicTopics({
    RequestCancellation? cancellation,
  });
}
