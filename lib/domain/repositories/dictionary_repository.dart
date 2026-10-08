import '../../core/request_cancellation.dart';
import '../models/dictionary.dart';
import '../models/service_envelopes.dart';

abstract interface class DictionaryRepository {
  Future<DictionaryCatalogue> catalogue({RequestCancellation? cancellation});
  Future<DictionaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  });
  Future<DictionaryIndex> index(
    String module, {
    RequestCancellation? cancellation,
  });
  Future<DictionaryEntry> entry(
    String module,
    String id, {
    RequestCancellation? cancellation,
  });
}
