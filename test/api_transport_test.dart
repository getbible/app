import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/data/api/api_configuration.dart';
import 'package:getbible_live/data/api/api_transport.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  final DateTime start = DateTime.utc(2026, 10, 8, 10);

  test(
    'service roots encode values, retain false/zero, avoid duplicate v1',
    () {
      final ApiConfiguration configuration = ApiConfiguration();
      expect(
        configuration
            .endpoint(ApiService.dictionaries)
            .uriFor('/v1/dictionaries.json')
            .toString(),
        'https://dictionaries.getbible.net/v1/dictionaries.json',
      );
      expect(
        configuration
            .endpoint(ApiService.commentaries)
            .uriFor('/v1/commentaries.json')
            .path,
        '/v1/commentaries.json',
      );
      expect(
        configuration
            .endpoint(ApiService.bookmarks)
            .uriFor('/topics.json')
            .path,
        '/v1/topics.json',
      );
      final Uri query = configuration.endpoint(ApiService.query).uriFor(
        'kjv/${Uri.encodeComponent('John 3:16; Psalm 23 / a&b')}',
        <String, Object?>{
          'case': false,
          'offset': 0,
          'q': 'faith & hope + שלום',
          'absent': null,
        },
      );
      expect(query.pathSegments.last, 'John 3:16; Psalm 23 / a&b');
      expect(query.queryParameters['case'], 'false');
      expect(query.queryParameters['offset'], '0');
      expect(query.queryParameters['q'], 'faith & hope + שלום');
      expect(query.queryParameters.containsKey('absent'), isFalse);
      expect(query.toString(), contains('%2F'));
      expect(
        () => configuration
            .endpoint(ApiService.query)
            .uriFor('https://other.invalid'),
        throwsArgumentError,
      );
      expect(
        () => configuration.endpoint(ApiService.bible).uriFor('../private'),
        throwsArgumentError,
      );
    },
  );

  test('valid JSON returns raw original UTF-8 bytes and identity', () async {
    const String body = '{"text":"word  \\nשלום 😀","zero":0,"false":false}';
    final ApiTransport transport = ApiTransport(
      client: MockClient(
        (_) async => http.Response(
          body,
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        ),
      ),
    );
    final ApiResponse response = await transport.get(
      ApiService.bible,
      'kjv/1/1.json',
    );
    expect(response.bytes, utf8.encode(body));
    expect(response.json['text'], 'word  \nשלום 😀');
    expect(response.json['zero'], 0);
    expect(response.json['false'], false);
    expect(response.uri.path, '/v3/kjv/1/1.json');
    expect(response.version, 'v3');
    expect(() => response.bytes[0] = 0, throwsUnsupportedError);
  });

  test('malformed JSON and invalid UTF-8 are typed failures', () async {
    final ApiTransport malformed = ApiTransport(
      client: MockClient(
        (_) async => http.Response('<html>not JSON</html>', 200),
      ),
    );
    await expectLater(
      malformed.getJson(ApiService.bible, 'translations.json'),
      throwsA(isA<ApiFormatException>()),
    );
    final ApiTransport badUtf8 = ApiTransport(
      client: MockClient((_) async => http.Response.bytes(<int>[0xff], 200)),
    );
    await expectLater(
      badUtf8.getText(ApiService.bible, 'kjv.sha'),
      throwsA(isA<ApiFormatException>()),
    );
    final ApiTransport wrongShape = ApiTransport(
      client: MockClient((_) async => http.Response('[]', 200)),
    );
    await expectLater(
      wrongShape.getJson(ApiService.bible, 'translations.json'),
      throwsA(isA<ApiFormatException>()),
    );
  });

  test(
    '404 and invalid-input HTML are status failures without retry',
    () async {
      int requests = 0;
      final ApiTransport missing = ApiTransport(
        client: MockClient((_) async {
          requests += 1;
          return http.Response('<html>missing</html>', 404);
        }),
      );
      await expectLater(
        missing.getJson(ApiService.bookmarks, 'topics/removed.json'),
        throwsA(isA<ResourceUnavailableException>()),
      );
      expect(requests, 1);
      final ApiTransport invalid = ApiTransport(
        client: MockClient((_) async => http.Response('bad reference', 400)),
      );
      await expectLater(
        invalid.getJson(ApiService.query, 'kjv/not-a-reference'),
        throwsA(isA<InvalidApiRequestException>()),
      );
    },
  );

  test('RFC 9457 fields retain the real error and are bounded', () async {
    final ApiTransport transport = ApiTransport(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'code': 'invalid_reference',
            'title': 'Invalid reference',
            'detail': 'The requested verse does not exist in this translation.',
          }),
          404,
        ),
      ),
    );
    await expectLater(
      transport.getJson(ApiService.query, 'kjv/John3:999'),
      throwsA(
        isA<ResourceUnavailableException>()
            .having(
              (ResourceUnavailableException value) => value.problem?.code,
              'code',
              'invalid_reference',
            )
            .having(
              (ResourceUnavailableException value) => value.message,
              'message',
              'The requested verse does not exist in this translation.',
            ),
      ),
    );
    final ApiTransport long = ApiTransport(
      client: MockClient(
        (_) async => http.Response(
          jsonEncode(<String, Object?>{
            'title': 'Invalid reference',
            'detail': 'x' * 1000,
          }),
          400,
        ),
      ),
    );
    await expectLater(
      long.getJson(ApiService.query, 'kjv/invalid'),
      throwsA(
        isA<InvalidApiRequestException>().having(
          (InvalidApiRequestException value) => value.problem?.detail?.length,
          'bounded detail',
          512,
        ),
      ),
    );
  });

  test(
    'malformed and oversized error JSON preserve status without body parsing errors',
    () async {
      for (final List<int> body in <List<int>>[
        utf8.encode('{broken'),
        <int>[0xff],
        utf8.encode(jsonEncode(<String, Object?>{'detail': 'x' * (20 * 1024)})),
      ]) {
        final ApiTransport transport = ApiTransport(
          client: MockClient((_) async => http.Response.bytes(body, 404)),
        );
        await expectLater(
          transport.getJson(ApiService.bookmarks, 'topics/missing.json'),
          throwsA(
            isA<ResourceUnavailableException>().having(
              (ResourceUnavailableException value) => value.problem,
              'problem',
              isNull,
            ),
          ),
        );
      }
    },
  );

  test('429 honors seconds Retry-After and bounded retries', () async {
    int requests = 0;
    final List<Duration> waits = <Duration>[];
    final ApiTransport transport = ApiTransport(
      client: MockClient((_) async {
        requests += 1;
        return requests < 3
            ? http.Response(
                '<html>rate limit</html>',
                429,
                headers: {'retry-after': '2'},
              )
            : http.Response('{"ok":true}', 200);
      }),
      delay: (Duration delay) async => waits.add(delay),
    );
    expect(
      (await transport.getJson(
        ApiService.search,
        'kjv',
        query: {'q': 'hope'},
      ))['ok'],
      isTrue,
    );
    expect(requests, 3);
    expect(waits, <Duration>[
      const Duration(seconds: 2),
      const Duration(seconds: 2),
    ]);
  });

  test(
    'long Retry-After is surfaced and never shortened into an early retry',
    () async {
      int requests = 0;
      final ApiTransport transport = ApiTransport(
        client: MockClient((_) async {
          requests += 1;
          return http.Response(
            'slow down',
            429,
            headers: {'retry-after': '120'},
          );
        }),
        delay: (_) async =>
            fail('Must not retry before the server permits it.'),
      );
      await expectLater(
        transport.getJson(ApiService.search, 'kjv'),
        throwsA(
          isA<RateLimitException>().having(
            (RateLimitException value) => value.retryAfter,
            'retryAfter',
            const Duration(seconds: 120),
          ),
        ),
      );
      expect(requests, 1);
    },
  );

  test('Retry-After supports HTTP dates', () async {
    int requests = 0;
    final List<Duration> waits = <Duration>[];
    final ApiTransport transport = ApiTransport(
      clock: () => start,
      client: MockClient((_) async {
        requests += 1;
        return requests == 1
            ? http.Response(
                'busy',
                503,
                headers: {'retry-after': 'Thu, 08 Oct 2026 10:00:03 GMT'},
              )
            : http.Response('{}', 200);
      }),
      delay: (Duration delay) async => waits.add(delay),
    );
    await transport.getJson(ApiService.query, 'kjv/John3:16');
    expect(waits, <Duration>[const Duration(seconds: 3)]);
  });

  test(
    '503 retry is bounded and a malformed error body is never parsed',
    () async {
      int requests = 0;
      final ApiTransport transport = ApiTransport(
        client: MockClient((_) async {
          requests += 1;
          return http.Response('<html>busy</html>', 503);
        }),
        delay: (_) async {},
      );
      await expectLater(
        transport.getJson(ApiService.search, 'kjv'),
        throwsA(
          isA<HttpStatusException>().having(
            (HttpStatusException value) => value.statusCode,
            'statusCode',
            503,
          ),
        ),
      );
      expect(requests, 3);
    },
  );

  test('timeout is typed and retry count remains bounded', () async {
    int requests = 0;
    final ApiTransport transport = ApiTransport(
      timeout: const Duration(milliseconds: 5),
      client: MockClient((_) {
        requests += 1;
        return Completer<http.Response>().future;
      }),
      delay: (_) async {},
    );
    await expectLater(
      transport.getJson(ApiService.bible, 'translations.json'),
      throwsA(isA<RequestTimeoutException>()),
    );
    expect(requests, 3);
  });

  test(
    'freshness uses remaining lifetime including Age and elapsed time',
    () async {
      DateTime now = start;
      int requests = 0;
      final ApiTransport transport = ApiTransport(
        clock: () => now,
        client: MockClient((_) async {
          requests += 1;
          return http.Response(
            '{"revision":$requests}',
            200,
            headers: {'cache-control': 'max-age=60', 'age': '50'},
          );
        }),
      );
      final ApiResponse initial = await transport.get(
        ApiService.bible,
        'translations.json',
      );
      expect(
        initial.cachePolicy.remainingLifetime(now),
        const Duration(seconds: 10),
      );
      now = now.add(const Duration(seconds: 9));
      expect(
        (await transport.get(ApiService.bible, 'translations.json')).source,
        ApiResponseSource.freshCache,
      );
      expect(requests, 1);
      now = now.add(const Duration(seconds: 1));
      expect(
        (await transport.get(
          ApiService.bible,
          'translations.json',
        )).json['revision'],
        2,
      );
      expect(requests, 2);
    },
  );

  test(
    'conditional 304 retains eligible body and renews header metadata',
    () async {
      DateTime now = start;
      final List<http.Request> requests = <http.Request>[];
      final ApiTransport transport = ApiTransport(
        clock: () => now,
        client: MockClient((http.Request request) async {
          requests.add(request);
          return requests.length == 1
              ? http.Response(
                  '{"saved":true}',
                  200,
                  headers: {
                    'etag': '"one"',
                    'cache-control': 'max-age=1',
                    'age': '1',
                    'date': 'Thu, 08 Oct 2026 10:00:00 GMT',
                  },
                )
              : http.Response(
                  '',
                  304,
                  headers: {'cache-control': 'max-age=60', 'etag': '"one"'},
                );
        }),
      );
      await transport.get(ApiService.query, 'kjv/John3:16');
      now = now.add(const Duration(seconds: 5));
      final ApiResponse validated = await transport.get(
        ApiService.query,
        'kjv/John3:16',
      );
      expect(requests.last.headers['if-none-match'], '"one"');
      expect(validated.source, ApiResponseSource.revalidated);
      expect(validated.json['saved'], true);
      expect(
        validated.cachePolicy.remainingLifetime(now),
        const Duration(seconds: 60),
      );
      await transport.get(ApiService.query, 'kjv/John3:16');
      expect(requests.length, 2);
    },
  );

  test('304 with no eligible body retries normally once', () async {
    final List<http.Request> requests = <http.Request>[];
    final ApiTransport transport = ApiTransport(
      client: MockClient((http.Request request) async {
        requests.add(request);
        return requests.length == 1
            ? http.Response('', 304)
            : http.Response('{"downloaded":true}', 200);
      }),
    );
    expect(
      (await transport.getJson(
        ApiService.bible,
        'translations.json',
      ))['downloaded'],
      true,
    );
    expect(requests.length, 2);
    expect(
      requests.every(
        (http.Request request) => !request.headers.containsKey('if-none-match'),
      ),
      isTrue,
    );
  });

  test(
    '304 never reuses an unvalidated body without a request validator',
    () async {
      int requests = 0;
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          requests += 1;
          expect(request.headers.containsKey('if-none-match'), false);
          expect(request.headers.containsKey('if-modified-since'), false);
          return switch (requests) {
            1 => http.Response('{"old":true}', 200),
            2 => http.Response('', 304),
            _ => http.Response('{"new":true}', 200),
          };
        }),
      );
      await transport.getJson(ApiService.bible, 'translations.json');
      expect(
        (await transport.getJson(ApiService.bible, 'translations.json'))['new'],
        true,
      );
      expect(requests, 3);
    },
  );

  test(
    'Last-Modified validator and no-store on revalidation are honored',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          requests.add(request);
          return switch (requests.length) {
            1 => http.Response(
              '{"saved":true}',
              200,
              headers: {
                'last-modified': 'Thu, 08 Oct 2026 10:00:00 GMT',
                'cache-control': 'no-cache',
              },
            ),
            2 => http.Response('', 304, headers: {'cache-control': 'no-store'}),
            _ => http.Response('{"new":true}', 200),
          };
        }),
      );
      await transport.getJson(ApiService.query, 'tst/Fixture1:1');
      expect(
        (await transport.getJson(ApiService.query, 'tst/Fixture1:1'))['saved'],
        true,
      );
      expect(
        requests[1].headers['if-modified-since'],
        'Thu, 08 Oct 2026 10:00:00 GMT',
      );
      expect(
        (await transport.getJson(ApiService.query, 'tst/Fixture1:1'))['new'],
        true,
      );
      expect(requests[2].headers.containsKey('if-modified-since'), false);
    },
  );

  test('repeated bodyless 304 becomes a typed bounded failure', () async {
    int requests = 0;
    final ApiTransport transport = ApiTransport(
      client: MockClient((_) async {
        requests += 1;
        return http.Response('', 304);
      }),
    );
    await expectLater(
      transport.getJson(ApiService.bible, 'translations.json'),
      throwsA(isA<HttpStatusException>()),
    );
    expect(requests, 2);
  });

  test(
    'no-cache validates every time; no-store keeps no body or validator',
    () async {
      final List<http.Request> requests = <http.Request>[];
      final ApiTransport transport = ApiTransport(
        client: MockClient((http.Request request) async {
          requests.add(request);
          return request.url.path.endsWith('private.json')
              ? http.Response(
                  '{}',
                  200,
                  headers: {
                    'cache-control': 'no-store, max-age=600',
                    'etag': '"private"',
                  },
                )
              : request.headers.containsKey('if-none-match')
              ? http.Response(
                  '',
                  304,
                  headers: {'cache-control': 'no-cache, max-age=600'},
                )
              : http.Response(
                  '{}',
                  200,
                  headers: {
                    'cache-control': 'no-cache, max-age=600',
                    'etag': '"public"',
                  },
                );
        }),
      );
      await transport.getJson(ApiService.bible, 'shared.json');
      await transport.getJson(ApiService.bible, 'shared.json');
      expect(requests.last.headers['if-none-match'], '"public"');
      await transport.getJson(ApiService.bible, 'private.json');
      await transport.getJson(ApiService.bible, 'private.json');
      expect(requests.last.headers.containsKey('if-none-match'), isFalse);
      expect(requests.length, 4);
    },
  );

  test(
    'cache keys separate effective query inputs and service identity',
    () async {
      int requests = 0;
      final ApiTransport transport = ApiTransport(
        client: MockClient((_) async {
          requests += 1;
          return http.Response(
            '{"number":$requests}',
            200,
            headers: {'cache-control': 'max-age=60'},
          );
        }),
      );
      await transport.getJson(
        ApiService.query,
        'kjv',
        query: {'offset': 0, 'case': false},
      );
      await transport.getJson(
        ApiService.query,
        'kjv',
        query: {'case': false, 'offset': 0},
      );
      expect(requests, 1);
      await transport.getJson(
        ApiService.query,
        'kjv',
        query: {'offset': 0, 'case': true},
      );
      await transport.getJson(
        ApiService.search,
        'kjv',
        query: {'offset': 0, 'case': false},
      );
      expect(requests, 3);
    },
  );

  test(
    'response limits reject advertised and streamed oversize bodies',
    () async {
      final ApiTransport advertised = ApiTransport(
        client: MockClient((_) async => http.Response('12345', 200)),
      );
      await expectLater(
        advertised.get(ApiService.bible, 'file.json', maxBytes: 4),
        throwsA(isA<ResponseTooLargeException>()),
      );
      final ApiTransport streamed = ApiTransport(
        client: MockClient.streaming(
          (_, _) async => http.StreamedResponse(
            Stream<List<int>>.fromIterable(<List<int>>[
              <int>[1, 2],
              <int>[3, 4, 5],
            ]),
            200,
          ),
        ),
      );
      await expectLater(
        streamed.get(ApiService.bible, 'file.json', maxBytes: 4),
        throwsA(isA<ResponseTooLargeException>()),
      );
    },
  );

  test(
    'cancellation completes promptly and cannot populate the cache',
    () async {
      final Completer<http.Response> response = Completer<http.Response>();
      int requests = 0;
      final ApiTransport transport = ApiTransport(
        client: MockClient((_) {
          requests += 1;
          return requests == 1
              ? response.future
              : Future<http.Response>.value(http.Response('{"new":true}', 200));
        }),
      );
      final RequestCancellation cancellation = RequestCancellation();
      final Future<ApiResponse> pending = transport.get(
        ApiService.query,
        'kjv/John3:16',
        cancellation: cancellation,
      );
      final Future<void> assertion = expectLater(
        pending,
        throwsA(isA<RequestCancelledException>()),
      );
      cancellation.cancel();
      await assertion;
      response.complete(
        http.Response(
          '{"old":true}',
          200,
          headers: {'cache-control': 'max-age=600'},
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(
        (await transport.getJson(ApiService.query, 'kjv/John3:16'))['new'],
        true,
      );
      expect(requests, 2);
    },
  );

  test(
    'request ownership prevents a late response after replacement or close',
    () {
      final RequestOwner owner = RequestOwner();
      final RequestCancellation old = owner.begin();
      final RequestCancellation current = owner.begin();
      expect(old.isCancelled, true);
      expect(owner.owns(old), false);
      expect(owner.owns(current), true);
      owner.cancel();
      expect(current.isCancelled, true);
      expect(owner.owns(current), false);
    },
  );

  test('conditional body from another API version is ineligible', () async {
    final ApiTransport source = ApiTransport(
      configuration: ApiConfiguration(
        endpoints: <ApiService, ApiServiceEndpoint>{
          ApiService.bible: ApiServiceEndpoint(
            baseUri: Uri.parse('https://api.getbible.net/v2'),
            version: 'v2',
          ),
        },
      ),
      client: MockClient(
        (_) async => http.Response(
          '{}',
          200,
          headers: {'etag': '"v2"', 'cache-control': 'max-age=600'},
        ),
      ),
    );
    final ApiResponse legacy = await source.get(
      ApiService.bible,
      'translations.json',
    );
    final ApiTransport target = ApiTransport(
      client: MockClient((http.Request request) async {
        expect(request.headers.containsKey('if-none-match'), false);
        expect(request.url.path, '/v3/translations.json');
        return http.Response('{"version":3}', 200);
      }),
    );
    expect(
      (await target.getJson(
        ApiService.bible,
        'translations.json',
        savedResponse: legacy,
      ))['version'],
      3,
    );
  });
}
