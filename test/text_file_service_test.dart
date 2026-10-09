import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/data/platform/platform_text_file_service.dart';
import 'package:getbible_live/services/text_file_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('rejects oversized metadata before opening untrusted stream', () async {
    bool opened = false;
    await expectLater(
      readBoundedText(
        length: () async => 9,
        openRead: () {
          opened = true;
          return const Stream<List<int>>.empty();
        },
        maxBytes: 8,
      ),
      throwsA(isA<TextFileException>()),
    );
    expect(opened, isFalse);
  });

  test(
    'enforces actual streamed bytes and cancels on inaccurate length',
    () async {
      bool cancelled = false;
      final StreamController<List<int>> stream = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      final Future<String> read = readBoundedText(
        length: () async => 1,
        openRead: () => stream.stream,
        maxBytes: 3,
      );
      final Future<void> rejected = expectLater(
        read,
        throwsA(isA<TextFileException>()),
      );
      stream.add(<int>[65, 66]);
      stream.add(<int>[67, 68]);
      await rejected;
      expect(cancelled, isTrue);
      await stream.close();
    },
  );

  test(
    'decodes multibyte UTF-8 split across chunks and rejects malformed input',
    () async {
      final List<int> encoded = utf8.encode('A😀é');
      expect(
        await readBoundedText(
          length: () async => encoded.length,
          openRead: () => Stream<List<int>>.fromIterable(
            encoded.map((int byte) => <int>[byte]),
          ),
          maxBytes: encoded.length,
        ),
        'A😀é',
      );
      await expectLater(
        readBoundedText(
          length: () async => 1,
          openRead: () => Stream<List<int>>.value(<int>[0xff]),
        ),
        throwsA(isA<TextFileException>()),
      );
    },
  );

  test('retains bytes when a stream reuses its mutable chunk buffer', () async {
    Stream<List<int>> chunks() async* {
      final List<int> buffer = <int>[65];
      yield buffer;
      buffer[0] = 66;
      yield buffer;
    }

    expect(
      await readBoundedText(length: () async => 2, openRead: chunks),
      'AB',
    );
  });

  const MethodChannel channel = MethodChannel('life.getbible.mobile/files');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('mobile pick forwards byte limit and preserves cancellation', () async {
    messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
      expect(call.method, 'pickTextFile');
      expect((call.arguments as Map<Object?, Object?>)['maxBytes'], 123);
      return null;
    });
    expect(
      await PlatformTextFileService(
        platform: TargetPlatform.android,
      ).pickText(maxBytes: 123),
      isNull,
    );
  });

  test(
    'mobile save waits for completion, rejects concurrency, and preserves cancellation',
    () async {
      final Completer<bool> pending = Completer<bool>();
      messenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) => pending.future,
      );
      final PlatformTextFileService files = PlatformTextFileService(
        platform: TargetPlatform.android,
      );
      final Future<TextSaveResult> save = files.saveText(
        text: '{}',
        filename: 'backup.json',
        mimeType: 'application/json',
      );
      await expectLater(files.pickText(), throwsA(isA<TextFileException>()));
      pending.complete(false);
      expect(await save, TextSaveResult.cancelled);
      messenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async => true,
      );
      expect(
        await files.saveText(
          text: '{}',
          filename: 'backup.json',
          mimeType: 'application/json',
        ),
        TextSaveResult.saved,
      );
    },
  );

  test(
    'native errors release busy state and sharing does not invent delivery',
    () async {
      final PlatformTextFileService files = PlatformTextFileService(
        platform: TargetPlatform.iOS,
      );
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        throw PlatformException(code: 'denied', message: 'Access denied.');
      });
      await expectLater(files.pickText(), throwsA(isA<TextFileException>()));
      messenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async => 'presented',
      );
      expect(
        await files.shareText(text: 'verse', subject: 'Scripture'),
        TextShareResult.presented,
      );
      messenger.setMockMethodCallHandler(
        channel,
        (MethodCall call) async => 'cancelled',
      );
      expect(
        await files.shareText(text: 'verse', subject: 'Scripture'),
        TextShareResult.cancelled,
      );
    },
  );

  test(
    'export rejects path traversal and large share before invoking platform',
    () async {
      int calls = 0;
      messenger.setMockMethodCallHandler(channel, (MethodCall call) async {
        calls++;
        return true;
      });
      final PlatformTextFileService files = PlatformTextFileService(
        platform: TargetPlatform.android,
      );
      await expectLater(
        files.saveText(
          text: 'text',
          filename: '../private.txt',
          mimeType: 'text/plain',
        ),
        throwsA(isA<TextFileException>()),
      );
      await expectLater(
        files.shareText(text: '😀' * maxSharedTextBytes, subject: 'large'),
        throwsA(isA<TextFileException>()),
      );
      expect(calls, 0);
    },
  );
}
