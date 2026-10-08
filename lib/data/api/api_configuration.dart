/// Public REST services supported by the reader. Each has an independent root.
enum ApiService { bible, query, search, dictionaries, commentaries, bookmarks }

final class ApiServiceEndpoint {
  ApiServiceEndpoint({
    required this.baseUri,
    required this.version,
    this.serializationVersion = 1,
    this.fallbackFreshness = Duration.zero,
  }) {
    if ((baseUri.scheme != 'https' && baseUri.scheme != 'http') ||
        baseUri.host.isEmpty ||
        baseUri.hasQuery ||
        baseUri.hasFragment ||
        version.isEmpty ||
        serializationVersion < 1 ||
        fallbackFreshness.isNegative) {
      throw ArgumentError(
        'An API endpoint requires a valid HTTP root/version.',
      );
    }
  }

  final Uri baseUri;
  final String version;
  final int serializationVersion;

  /// Conservative fallback when a browser cannot expose cache headers.
  final Duration fallbackFreshness;

  Uri uriFor(String path, [Map<String, Object?> query = const {}]) {
    final Uri relative = Uri.parse(path);
    if (relative.hasScheme || relative.hasAuthority || relative.hasFragment) {
      throw ArgumentError.value(path, 'path', 'Use an API resource path.');
    }
    final List<String> root = baseUri.pathSegments
        .where((String value) => value.isNotEmpty)
        .toList();
    final List<String> resource = relative.pathSegments
        .where((String value) => value.isNotEmpty)
        .toList();
    // Dictionary/commentary OpenAPI routes include /v1, whereas bookmarks
    // are relative to their v1 server. Accept both without double-prefixing.
    if (root.isNotEmpty && resource.isNotEmpty && resource.first == root.last) {
      resource.removeAt(0);
    }
    if (resource.any((String value) => value == '..' || value == '.')) {
      throw ArgumentError.value(path, 'path', 'Parent paths are not allowed.');
    }
    final Map<String, List<String>> parameters = <String, List<String>>{
      ...relative.queryParametersAll,
    };
    for (final MapEntry<String, Object?> entry in query.entries) {
      final Object? value = entry.value;
      if (value == null) continue;
      parameters[entry.key] = value is Iterable
          ? value.map((Object? item) => item.toString()).toList()
          : <String>[value.toString()];
    }
    // Stable ordering means equivalent effective inputs share one cache key.
    final List<String> keys = parameters.keys.toList()..sort();
    return baseUri.replace(
      pathSegments: <String>[...root, ...resource],
      queryParameters: keys.isEmpty
          ? null
          : <String, List<String>>{
              for (final String key in keys) key: parameters[key]!,
            },
    );
  }
}

final class ApiConfiguration {
  ApiConfiguration({Map<ApiService, ApiServiceEndpoint> endpoints = const {}})
    : _endpoints = <ApiService, ApiServiceEndpoint>{
        for (final ApiService service in ApiService.values)
          service: endpoints[service] ?? _defaultEndpoint(service),
      };

  final Map<ApiService, ApiServiceEndpoint> _endpoints;

  ApiServiceEndpoint endpoint(ApiService service) => _endpoints[service]!;

  static ApiServiceEndpoint _defaultEndpoint(ApiService service) {
    final String host = switch (service) {
      ApiService.bible => 'api.getbible.net',
      ApiService.query => 'query.getbible.net',
      ApiService.search => 'search.getbible.net',
      ApiService.dictionaries => 'dictionaries.getbible.net',
      ApiService.commentaries => 'commentaries.getbible.net',
      ApiService.bookmarks => 'bookmarks.getbible.net',
    };
    final String version = switch (service) {
      ApiService.bible || ApiService.query || ApiService.search => 'v3',
      _ => 'v1',
    };
    return ApiServiceEndpoint(
      baseUri: Uri.parse('https://$host/$version'),
      version: version,
    );
  }
}
