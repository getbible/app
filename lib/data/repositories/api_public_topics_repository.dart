import '../../core/errors.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/public_topic.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/repositories/public_topics_repository.dart';
import '../api/api_configuration.dart';
import '../api/api_transport.dart';
import '../api/public_topic_adapter.dart';

/// Online reads never retrieve catalog.json/all.json or mutate private data.
final class ApiPublicTopicsRepository implements PublicTopicsRepository {
  ApiPublicTopicsRepository(this.transport);
  final ApiTransport transport;
  PublicTopicDiscovery? _discovery;
  final Map<String, ApiResponse> _recentResources = <String, ApiResponse>{};
  final Set<String> _validatedPaths = <String>{};

  @override
  String get sourceScope =>
      'bookmarks:v1:${transport.configuration.endpoint(ApiService.bookmarks).baseUri}';

  @override
  Future<PublicTopicDiscovery> discovery({
    RequestCancellation? cancellation,
  }) async {
    final PublicTopicDiscovery current = await _load(
      'index.json',
      PublicTopicAdapter.discovery,
      cancellation,
    );
    if (_discovery != null && _discovery!.checksum != current.checksum) {
      for (final ApiResponse response in _recentResources.values) {
        transport.discardResponse(response);
      }
      _recentResources.clear();
      _validatedPaths.clear();
    }
    _discovery = current;
    return current;
  }

  @override
  Future<PublicTopicCatalogue> catalogue({RequestCancellation? cancellation}) =>
      _load(
        'topics.json',
        PublicTopicAdapter.catalogue,
        cancellation,
        kind: 'catalogue',
      );

  @override
  Future<List<PublicTopicLocale>> locales({
    RequestCancellation? cancellation,
  }) => _load(
    'locales.json',
    PublicTopicAdapter.locales,
    cancellation,
    kind: 'locales',
  );

  @override
  Future<PublicTopicNames> names(
    String locale, {
    RequestCancellation? cancellation,
  }) {
    PublicTopicAdapter.validateLocale(locale);
    return _load(
      'locales/$locale.json',
      (Object? value) => PublicTopicAdapter.names(value, locale: locale),
      cancellation,
      kind: 'names',
    );
  }

  @override
  Future<PublicTopic> topic(String id, {RequestCancellation? cancellation}) {
    PublicTopicAdapter.validateId(id);
    return _load(
      'topics/$id.json',
      (Object? value) => PublicTopicAdapter.topic(value, expectedId: id),
      cancellation,
      kind: 'topic',
    );
  }

  @override
  Future<PublicTopicAssociations> chapter(
    int book,
    int chapter, {
    RequestCancellation? cancellation,
  }) {
    if (book < 1 || book > 66 || chapter < 1 || chapter > 150) {
      throw const FormatException(
        'The public-topic dataset covers canonical chapters in books 1–66.',
      );
    }
    return _load(
      'verses/$book/$chapter.json',
      (Object? value) =>
          PublicTopicAdapter.chapter(value, book: book, chapter: chapter),
      cancellation,
      kind: 'chapter',
    );
  }

  Future<T> _load<T>(
    String path,
    T Function(Object?) parser,
    RequestCancellation? cancellation, {
    String? kind,
  }) async {
    final ApiResponse response = await transport.get(
      ApiService.bookmarks,
      path,
      cancellation: cancellation,
      // Revalidate each resource once after a catalogue revision, including a
      // previously cached topic that has since been deleted. No cache-busting
      // query parameters or bulk downloads are needed.
      forceRefresh: path == 'index.json' || !_validatedPaths.contains(path),
    );
    try {
      final T result = parser(response.json);
      cancellation?.throwIfCancelled();
      if (kind != null) _recentResources[kind] = response;
      if (_validatedPaths.length >= 256) _validatedPaths.clear();
      _validatedPaths.add(path);
      return result;
    } on ApiFormatException {
      transport.discardResponse(response);
      rethrow;
    }
  }
}
