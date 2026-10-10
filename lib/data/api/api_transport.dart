import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import '../../core/errors.dart';
import '../../core/json.dart';
import '../../core/request_cancellation.dart';
import 'api_configuration.dart';

/// Limits apply while reading a response, before UTF-8 or JSON decoding.
abstract final class ApiResponseLimits {
  static const int metadata = 4 * 1024 * 1024;
  static const int chapter = 8 * 1024 * 1024;
  static const int query = 8 * 1024 * 1024;
  static const int bulk = 128 * 1024 * 1024;
}

final class ApiRetryPolicy {
  const ApiRetryPolicy({
    this.maxRetries = 2,
    this.initialDelay = const Duration(milliseconds: 250),
    this.maxDelay = const Duration(seconds: 5),
  });

  final int maxRetries;
  final Duration initialDelay;

  /// A longer Retry-After is returned to the caller instead of blocking UI.
  final Duration maxDelay;

  bool retriesStatus(int status) =>
      status == 408 ||
      status == 429 ||
      status == 502 ||
      status == 503 ||
      status == 504;

  Duration delayFor(int attempt) => Duration(
    microseconds: math.min(
      initialDelay.inMicroseconds * (1 << math.min(attempt, 20)),
      maxDelay.inMicroseconds,
    ),
  );
}

enum ApiResponseSource { network, freshCache, revalidated }

/// Cache policy is derived from exposed HTTP headers. A missing header does not
/// imply permanent freshness, particularly in browsers with restricted CORS.
final class ApiCachePolicy {
  ApiCachePolicy._({
    required this.noStore,
    required this.noCache,
    required this.initialAge,
    required this.freshnessLifetime,
    required this.receivedAt,
  });

  factory ApiCachePolicy.fromHeaders(
    Map<String, String> headers,
    DateTime receivedAt, {
    Duration fallbackFreshness = Duration.zero,
  }) {
    final Map<String, String> normalized = _lowercaseHeaders(headers);
    final Map<String, String?> directives = <String, String?>{};
    for (final String part in (normalized['cache-control'] ?? '').split(',')) {
      final int equals = part.indexOf('=');
      final String name = (equals < 0 ? part : part.substring(0, equals))
          .trim()
          .toLowerCase();
      if (name.isEmpty) continue;
      directives[name] = equals < 0
          ? null
          : part.substring(equals + 1).trim().replaceAll('"', '');
    }
    final int? seconds = int.tryParse(directives['max-age'] ?? '');
    final DateTime? date = _parseHttpDate(normalized['date']);
    final DateTime? expires = _parseHttpDate(normalized['expires']);
    final Duration lifetime;
    if (seconds != null && seconds >= 0) {
      lifetime = Duration(seconds: seconds);
    } else if (expires != null) {
      lifetime = _nonnegative(expires.difference(date ?? receivedAt));
    } else {
      lifetime = fallbackFreshness;
    }
    final int ageSeconds = math.max(
      0,
      int.tryParse(normalized['age'] ?? '') ?? 0,
    );
    final Duration apparentAge = date == null
        ? Duration.zero
        : _nonnegative(receivedAt.difference(date));
    return ApiCachePolicy._(
      noStore:
          directives.containsKey('no-store') ||
          (normalized['vary'] ?? '').trim() == '*',
      noCache: directives.containsKey('no-cache'),
      initialAge: Duration(
        microseconds: math.max(
          apparentAge.inMicroseconds,
          Duration(seconds: ageSeconds).inMicroseconds,
        ),
      ),
      freshnessLifetime: lifetime,
      receivedAt: receivedAt,
    );
  }

  final bool noStore;
  final bool noCache;
  final Duration initialAge;
  final Duration freshnessLifetime;
  final DateTime receivedAt;

  Duration remainingLifetime(DateTime now) => _nonnegative(
    freshnessLifetime - initialAge - _nonnegative(now.difference(receivedAt)),
  );

  bool isFresh(DateTime now) =>
      !noStore && !noCache && remainingLifetime(now) > Duration.zero;
}

/// Original response bytes and source identity remain available for hash checks.
/// A 304 response is represented with the saved body and merged header metadata.
final class ApiResponse {
  ApiResponse({
    required this.service,
    required this.version,
    required this.serializationVersion,
    required this.uri,
    required List<int> bytes,
    required Map<String, String> headers,
    required this.receivedAt,
    required this.cachePolicy,
    this.source = ApiResponseSource.network,
    this.accept = 'application/json',
  }) : bytes = Uint8List.fromList(bytes).asUnmodifiableView(),
       headers = Map<String, String>.unmodifiable(_lowercaseHeaders(headers)),
       _cacheIdentity = Object();

  ApiResponse._withSource(ApiResponse value, this.source)
    : service = value.service,
      version = value.version,
      serializationVersion = value.serializationVersion,
      uri = value.uri,
      bytes = value.bytes,
      headers = value.headers,
      receivedAt = value.receivedAt,
      cachePolicy = value.cachePolicy,
      accept = value.accept,
      _cacheIdentity = value._cacheIdentity;

  final Object _cacheIdentity;
  final ApiService service;
  final String version;
  final int serializationVersion;
  final Uri uri;
  final List<int> bytes;
  final Map<String, String> headers;
  final DateTime receivedAt;
  final ApiCachePolicy cachePolicy;
  final ApiResponseSource source;
  final String accept;

  String get text {
    try {
      return utf8.decode(bytes, allowMalformed: false);
    } on FormatException catch (error) {
      throw ApiFormatException(
        'The getBible response is not valid UTF-8.',
        error,
      );
    }
  }

  JsonMap get json {
    try {
      return requireJsonMap(jsonDecode(text), 'getBible response');
    } on FormatException catch (error) {
      throw ApiFormatException(
        'The getBible service returned malformed JSON.',
        error,
      );
    }
  }
}

/// One bounded, injectable HTTP boundary for all public getBible services.
/// Persistent Bible caches and explicit offline installations are owned by
/// repositories; this small HTTP cache never replaces their saved content.
final class ApiTransport {
  ApiTransport({
    http.Client? client,
    ApiConfiguration? configuration,
    this.timeout = const Duration(seconds: 15),
    this.retryPolicy = const ApiRetryPolicy(),
    this.maxCacheEntries = 32,
    this.maxCacheBytes = 8 * 1024 * 1024,
    DateTime Function()? clock,
    Future<void> Function(Duration)? delay,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       configuration = configuration ?? ApiConfiguration(),
       _clock = clock ?? DateTime.now,
       _delay = delay ?? Future<void>.delayed {
    if (timeout <= Duration.zero ||
        retryPolicy.maxRetries < 0 ||
        retryPolicy.initialDelay.isNegative ||
        retryPolicy.maxDelay.isNegative ||
        maxCacheEntries < 0 ||
        maxCacheBytes < 0) {
      throw ArgumentError(
        'HTTP timeout, retry and cache limits must be valid.',
      );
    }
  }

  final http.Client _client;
  final bool _ownsClient;
  final ApiConfiguration configuration;
  final Duration timeout;
  final ApiRetryPolicy retryPolicy;
  final int maxCacheEntries;
  final int maxCacheBytes;
  final DateTime Function() _clock;
  final Future<void> Function(Duration) _delay;
  final Map<String, ApiResponse> _cache = <String, ApiResponse>{};
  int _cachedBytes = 0;
  int _cacheEpoch = 0;
  bool _closed = false;

  Future<JsonMap> getJson(
    ApiService service,
    String path, {
    Map<String, Object?> query = const {},
    int maxBytes = ApiResponseLimits.metadata,
    RequestCancellation? cancellation,
    ApiResponse? savedResponse,
    bool forceRefresh = false,
  }) async {
    final ApiResponse response = await get(
      service,
      path,
      query: query,
      maxBytes: maxBytes,
      cancellation: cancellation,
      savedResponse: savedResponse,
      forceRefresh: forceRefresh,
    );
    try {
      return response.json;
    } on ApiFormatException {
      discardResponse(response);
      rethrow;
    }
  }

  Future<String> getText(
    ApiService service,
    String path, {
    Map<String, Object?> query = const {},
    String accept = 'text/plain',
    int maxBytes = ApiResponseLimits.metadata,
    RequestCancellation? cancellation,
    ApiResponse? savedResponse,
    bool forceRefresh = false,
  }) async {
    final ApiResponse response = await get(
      service,
      path,
      query: query,
      accept: accept,
      maxBytes: maxBytes,
      cancellation: cancellation,
      savedResponse: savedResponse,
      forceRefresh: forceRefresh,
    );
    try {
      return response.text;
    } on ApiFormatException {
      discardResponse(response);
      rethrow;
    }
  }

  Future<ApiResponse> get(
    ApiService service,
    String path, {
    Map<String, Object?> query = const {},
    String accept = 'application/json',
    int maxBytes = ApiResponseLimits.metadata,
    RequestCancellation? cancellation,
    ApiResponse? savedResponse,
    bool forceRefresh = false,
  }) async {
    if (_closed) throw StateError('The API transport has been closed.');
    final cacheEpoch = _cacheEpoch;
    if (maxBytes < 1) throw ArgumentError.value(maxBytes, 'maxBytes');
    cancellation?.throwIfCancelled();
    final ApiServiceEndpoint endpoint = configuration.endpoint(service);
    final Uri uri = endpoint.uriFor(path, query);
    final String key = _requestKey(service, endpoint, uri, accept);
    ApiResponse? saved = savedResponse ?? _cache[key];
    if (!_eligible(saved, service, endpoint, uri, accept, maxBytes)) {
      saved = null;
    }
    if (!forceRefresh && saved != null && saved.cachePolicy.isFresh(_clock())) {
      return _copy(saved, source: ApiResponseSource.freshCache);
    }
    bool unconditional304Retry = false;
    int attempt = 0;
    while (true) {
      cancellation?.throwIfCancelled();
      final Map<String, String> headers = <String, String>{'accept': accept};
      if (saved != null) {
        final String? etag = saved.headers['etag'];
        final String? modified = saved.headers['last-modified'];
        if (etag != null && etag.isNotEmpty) {
          headers['if-none-match'] = etag;
        } else if (modified != null && modified.isNotEmpty) {
          headers['if-modified-since'] = modified;
        }
      }
      try {
        final _RawResponse raw = await _request(
          uri,
          headers,
          maxBytes,
          cancellation,
        );
        cancellation?.throwIfCancelled();
        if (raw.statusCode == 304) {
          if (saved == null ||
              (!headers.containsKey('if-none-match') &&
                  !headers.containsKey('if-modified-since'))) {
            if (unconditional304Retry) {
              throw HttpStatusException(
                statusCode: 304,
                uri: uri,
                message:
                    'getBible returned a conditional response without saved content.',
              );
            }
            unconditional304Retry = true;
            saved = null;
            continue;
          }
          final Map<String, String> merged = <String, String>{
            ...saved.headers,
            ...raw.headers,
          };
          // Age and Date describe this validation transaction. Reusing their
          // old values would incorrectly exhaust an otherwise renewed lifetime.
          if (!raw.headers.containsKey('age')) merged.remove('age');
          if (!raw.headers.containsKey('date')) merged.remove('date');
          final ApiResponse result = _response(
            service,
            endpoint,
            uri,
            saved.bytes,
            merged,
            raw.receivedAt,
            accept,
            ApiResponseSource.revalidated,
          );
          if (cacheEpoch == _cacheEpoch) _store(key, result);
          return result;
        }
        if (raw.statusCode < 200 || raw.statusCode >= 300) {
          final Duration? retryAfter = _retryAfter(raw.headers, raw.receivedAt);
          final HttpStatusException error = _statusError(
            raw.statusCode,
            uri,
            retryAfter,
            _problem(raw.bytes),
          );
          if (!retryPolicy.retriesStatus(raw.statusCode) ||
              attempt >= retryPolicy.maxRetries ||
              (retryAfter != null && retryAfter > retryPolicy.maxDelay)) {
            throw error;
          }
          await _wait(
            retryAfter ?? retryPolicy.delayFor(attempt),
            cancellation,
          );
          attempt += 1;
          continue;
        }
        final ApiResponse result = _response(
          service,
          endpoint,
          uri,
          raw.bytes,
          raw.headers,
          raw.receivedAt,
          accept,
          ApiResponseSource.network,
        );
        if (cacheEpoch == _cacheEpoch) _store(key, result);
        return result;
      } on RequestTimeoutException {
        if (attempt >= retryPolicy.maxRetries) rethrow;
        await _wait(retryPolicy.delayFor(attempt), cancellation);
        attempt += 1;
      } on http.ClientException catch (error) {
        cancellation?.throwIfCancelled();
        if (attempt >= retryPolicy.maxRetries) {
          throw NetworkException('The getBible service is unavailable.', error);
        }
        await _wait(retryPolicy.delayFor(attempt), cancellation);
        attempt += 1;
      }
    }
  }

  Future<_RawResponse> _request(
    Uri uri,
    Map<String, String> headers,
    int maxBytes,
    RequestCancellation? cancellation,
  ) async {
    final RequestCancellation lifetime = RequestCancellation();
    if (cancellation != null) {
      unawaited(cancellation.whenCancelled.then((_) => lifetime.cancel()));
    }
    final Future<_RawResponse> operation = () async {
      final http.AbortableRequest request = http.AbortableRequest(
        'GET',
        uri,
        abortTrigger: lifetime.whenCancelled,
      )..headers.addAll(headers);
      final http.StreamedResponse response = await _client.send(request);
      final DateTime receivedAt = _clock();
      final Map<String, String> responseHeaders = _lowercaseHeaders(
        response.headers,
      );
      // Error hosts may return HTML or an unbounded error body. Status handling
      // does not depend on decoding it. Cancel/discard the stream immediately.
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final List<int> errorBody = await _readProblemBody(response);
        return _RawResponse(
          response.statusCode,
          errorBody,
          responseHeaders,
          receivedAt,
        );
      }
      final int? length = response.contentLength;
      if (length != null && length > maxBytes) {
        await response.stream.listen(null).cancel();
        throw ResponseTooLargeException(maxBytes);
      }
      final BytesBuilder bytes = BytesBuilder(copy: false);
      await for (final List<int> chunk in response.stream) {
        lifetime.throwIfCancelled();
        if (bytes.length + chunk.length > maxBytes) {
          throw ResponseTooLargeException(maxBytes);
        }
        bytes.add(chunk);
      }
      return _RawResponse(
        response.statusCode,
        bytes.takeBytes(),
        responseHeaders,
        receivedAt,
      );
    }();
    try {
      return await lifetime.bind(operation).timeout(timeout);
    } on TimeoutException catch (error) {
      lifetime.cancel();
      throw RequestTimeoutException(error);
    } on RequestCancelledException {
      lifetime.cancel();
      rethrow;
    } finally {
      // Disconnect the abort trigger after consuming the response as well.
      lifetime.cancel();
    }
  }

  Future<void> _wait(Duration delay, RequestCancellation? cancellation) async {
    if (cancellation == null) {
      await _delay(delay);
    } else {
      await cancellation.bind(_delay(delay));
    }
  }

  bool _eligible(
    ApiResponse? saved,
    ApiService service,
    ApiServiceEndpoint endpoint,
    Uri uri,
    String accept,
    int maxBytes,
  ) =>
      saved != null &&
      !saved.cachePolicy.noStore &&
      saved.service == service &&
      saved.version == endpoint.version &&
      saved.serializationVersion == endpoint.serializationVersion &&
      saved.uri == uri &&
      saved.accept == accept &&
      saved.bytes.length <= maxBytes;

  ApiResponse _response(
    ApiService service,
    ApiServiceEndpoint endpoint,
    Uri uri,
    List<int> bytes,
    Map<String, String> headers,
    DateTime receivedAt,
    String accept,
    ApiResponseSource source,
  ) => ApiResponse(
    service: service,
    version: endpoint.version,
    serializationVersion: endpoint.serializationVersion,
    uri: uri,
    bytes: bytes,
    headers: headers,
    receivedAt: receivedAt,
    cachePolicy: ApiCachePolicy.fromHeaders(
      headers,
      receivedAt,
      fallbackFreshness: endpoint.fallbackFreshness,
    ),
    source: source,
    accept: accept,
  );

  ApiResponse _copy(ApiResponse value, {required ApiResponseSource source}) =>
      ApiResponse._withSource(value, source);

  /// Discard one malformed representation without evicting unrelated services
  /// or a newer response that completed while this representation was parsed.
  /// Fresh-cache copies keep the identity of their original cached snapshot.
  void discardResponse(ApiResponse response) {
    final String key = _key(response);
    final ApiResponse? cached = _cache[key];
    if (cached != null &&
        identical(cached._cacheIdentity, response._cacheIdentity)) {
      _remove(key);
    }
  }

  String _requestKey(
    ApiService service,
    ApiServiceEndpoint endpoint,
    Uri uri,
    String accept,
  ) =>
      '${service.name}|${endpoint.version}|${endpoint.serializationVersion}|$uri|$accept';

  String _key(ApiResponse value) =>
      '${value.service.name}|${value.version}|${value.serializationVersion}|${value.uri}|${value.accept}';

  void _remove(String key) {
    final ApiResponse? previous = _cache.remove(key);
    if (previous != null) _cachedBytes -= previous.bytes.length;
  }

  void _store(String key, ApiResponse response) {
    _remove(key);
    if (response.cachePolicy.noStore ||
        maxCacheEntries == 0 ||
        response.bytes.length > maxCacheBytes) {
      return;
    }
    while (_cache.isNotEmpty &&
        (_cache.length >= maxCacheEntries ||
            _cachedBytes + response.bytes.length > maxCacheBytes)) {
      _remove(_cache.keys.first);
    }
    _cache[key] = response;
    _cachedBytes += response.bytes.length;
  }

  void clearCache() {
    // Requests that started before removal may still answer their callers,
    // but must not silently restore the content the user just cleared.
    _cacheEpoch++;
    _cache.clear();
    _cachedBytes = 0;
  }

  void close() {
    _closed = true;
    clearCache();
    if (_ownsClient) _client.close();
  }
}

final class _RawResponse {
  const _RawResponse(
    this.statusCode,
    this.bytes,
    this.headers,
    this.receivedAt,
  );
  final int statusCode;
  final List<int> bytes;
  final Map<String, String> headers;
  final DateTime receivedAt;
}

HttpStatusException _statusError(
  int status,
  Uri uri,
  Duration? retryAfter,
  ApiProblemDetails? problem,
) => switch (status) {
  404 => ResourceUnavailableException(uri, problem: problem),
  429 => RateLimitException(uri, retryAfter: retryAfter, problem: problem),
  400 || 422 => InvalidApiRequestException(
    statusCode: status,
    uri: uri,
    problem: problem,
  ),
  _ => HttpStatusException(
    statusCode: status,
    uri: uri,
    retryAfter: retryAfter,
    problem: problem,
    message:
        problem?.detail ?? problem?.title ?? 'getBible returned HTTP $status.',
  ),
};

Future<List<int>> _readProblemBody(http.StreamedResponse response) async {
  const int limit = 16 * 1024;
  if ((response.contentLength ?? 0) > limit) {
    await response.stream.listen(null).cancel();
    return const [];
  }
  final BytesBuilder bytes = BytesBuilder(copy: false);
  try {
    await for (final List<int> chunk in response.stream) {
      if (bytes.length + chunk.length > limit) return const [];
      bytes.add(chunk);
    }
  } on Exception {
    // A known HTTP status remains useful even if its optional body is broken.
    return const [];
  }
  return bytes.takeBytes();
}

ApiProblemDetails? _problem(List<int> bytes) {
  if (bytes.isEmpty) return null;
  try {
    final String text = utf8.decode(bytes, allowMalformed: false).trim();
    if (!text.startsWith('{')) return null;
    final Object? value = jsonDecode(text);
    if (value is! Map) return null;
    String? field(String key) {
      final Object? raw = value[key];
      if (raw is! String || raw.trim().isEmpty) return null;
      return String.fromCharCodes(raw.trim().runes.take(512));
    }

    final String? code = field('code');
    final String? title = field('title');
    final String? detail = field('detail');
    if (code == null && title == null && detail == null) return null;
    return ApiProblemDetails(code: code, title: title, detail: detail);
  } on FormatException {
    return null;
  }
}

Duration? _retryAfter(Map<String, String> headers, DateTime now) {
  final String? raw = headers['retry-after'];
  if (raw == null) return null;
  final int? seconds = int.tryParse(raw.trim());
  if (seconds != null && seconds >= 0) return Duration(seconds: seconds);
  final DateTime? date = _parseHttpDate(raw);
  return date == null ? null : _nonnegative(date.difference(now));
}

Map<String, String> _lowercaseHeaders(Map<String, String> headers) => headers
    .map((String key, String value) => MapEntry(key.toLowerCase(), value));

Duration _nonnegative(Duration value) =>
    value.isNegative ? Duration.zero : value;

// HTTP dates use English month names regardless of the user's locale. Parsing
// here keeps the shared transport usable on Web without importing dart:io.
DateTime? _parseHttpDate(String? value) {
  if (value == null) return null;
  final RegExpMatch? match = RegExp(
    r'^(?:[A-Za-z]+,\s*)?(\d{1,2})[ -]([A-Za-z]{3})[ -](\d{2,4})\s+(\d{2}):(\d{2}):(\d{2})\s+GMT$',
    caseSensitive: false,
  ).firstMatch(value.trim());
  if (match == null) return null;
  const List<String> months = <String>[
    'jan',
    'feb',
    'mar',
    'apr',
    'may',
    'jun',
    'jul',
    'aug',
    'sep',
    'oct',
    'nov',
    'dec',
  ];
  final int month = months.indexOf(match.group(2)!.toLowerCase()) + 1;
  int year = int.parse(match.group(3)!);
  if (year < 100) year += year >= 70 ? 1900 : 2000;
  final int day = int.parse(match.group(1)!);
  final int hour = int.parse(match.group(4)!);
  final int minute = int.parse(match.group(5)!);
  final int second = int.parse(match.group(6)!);
  if (month < 1 ||
      day < 1 ||
      day > 31 ||
      hour > 23 ||
      minute > 59 ||
      second > 59) {
    return null;
  }
  return DateTime.utc(year, month, day, hour, minute, second);
}
