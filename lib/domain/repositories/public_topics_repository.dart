import '../../core/request_cancellation.dart';
import '../models/public_topic.dart';
import '../models/service_envelopes.dart';

abstract interface class PublicTopicsRepository {
  String get sourceScope;
  Future<PublicTopicDiscovery> discovery({RequestCancellation? cancellation});
  Future<PublicTopicCatalogue> catalogue({RequestCancellation? cancellation});
  Future<List<PublicTopicLocale>> locales({RequestCancellation? cancellation});
  Future<PublicTopicNames> names(
    String locale, {
    RequestCancellation? cancellation,
  });
  Future<PublicTopic> topic(String id, {RequestCancellation? cancellation});
  Future<PublicTopicAssociations> chapter(
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  });
}

abstract interface class PublicTopicCopyRepository {
  Future<PublicTopicCopyPreview> preview({
    required PublicTopic topic,
    required String sourceScope,
    required String translation,
  });
  Future<PublicTopicCopyResult> copy(PublicTopicCopyPreview preview);
}
