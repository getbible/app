import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/core/ui_strings.dart';
import 'package:getbible/presentation/widgets/text_export_actions.dart';
import 'package:getbible/services/text_file_service.dart';

void main() {
  testWidgets(
    'save cancellation and browser request have truthful distinct feedback',
    (WidgetTester tester) async {
      final FakeFiles files = FakeFiles();
      await tester.pumpWidget(_app(files));
      await tester.tap(find.text('Save file'));
      await tester.pumpAndSettle();
      expect(find.text('Save cancelled.'), findsOneWidget);
      expect(find.text('File saved.'), findsNothing);
      files.saveResult = TextSaveResult.downloadRequested;
      await tester.tap(find.text('Save file'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Download requested.'), findsOneWidget);
      expect(find.text('File saved.'), findsNothing);
    },
  );

  testWidgets(
    'clipboard failure does not claim copied and save fallback remains usable',
    (WidgetTester tester) async {
      final FakeFiles files = FakeFiles()..failCopy = true;
      await tester.pumpWidget(_app(files));
      await tester.tap(find.text('Copy'));
      await tester.pumpAndSettle();
      expect(find.text('Clipboard unavailable.'), findsOneWidget);
      expect(find.text('Text copied.'), findsNothing);
      files.saveResult = TextSaveResult.saved;
      await tester.tap(find.text('Save file'));
      await tester.pumpAndSettle();
      expect(find.text('File saved.'), findsOneWidget);
    },
  );

  testWidgets('an old async result cannot label edited content as saved', (
    WidgetTester tester,
  ) async {
    final FakeFiles files = FakeFiles()
      ..pendingSave = Completer<TextSaveResult>();
    await tester.pumpWidget(_app(files));
    await tester.tap(find.text('Save file'));
    await tester.pump();
    await tester.pumpWidget(_app(files, text: 'new text'));
    files.pendingSave!.complete(TextSaveResult.saved);
    await tester.pumpAndSettle();
    expect(find.text('File saved.'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
  });

  testWidgets('Arabic actions preserve private Unicode text at 200% scale', (
    WidgetTester tester,
  ) async {
    final strings = (await tester.runAsync(() => UiStrings.load('ar')))!;
    const privateText = 'My {copy} notebook — λόγος 😀 العربية';
    final files = FakeFiles();
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: UiStringsScope(
          strings: strings,
          child: Directionality(
            textDirection: TextDirection.rtl,
            child: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: _actions(files, privateText),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    expect(find.text(strings.text('Save file')), findsOneWidget);
    expect(find.text('Save file'), findsNothing);
    await tester.tap(find.text(strings('copy')));
    await tester.pumpAndSettle();
    expect(files.copiedText, privateText);
    expect(find.text(strings.text('Text copied.')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('actions fit a narrow screen at large text scale', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(16),
              child: _actions(FakeFiles(), 'text'),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}

Widget _actions(FakeFiles files, String text) => TextExportActions(
  text: text,
  filename: 'scripture.md',
  mimeType: 'text/markdown',
  subject: 'Scripture',
  files: files,
);
Widget _app(FakeFiles files, {String text = 'text'}) =>
    MaterialApp(home: Scaffold(body: _actions(files, text)));

class FakeFiles implements TextFileService {
  TextSaveResult saveResult = TextSaveResult.cancelled;
  bool failCopy = false;
  String? copiedText;
  Completer<TextSaveResult>? pendingSave;
  @override
  Future<void> copyText(String text) async {
    if (failCopy) throw const TextFileException('Clipboard unavailable.');
    copiedText = text;
  }

  @override
  Future<String?> pickText({int maxBytes = maxTextFileBytes}) async => null;
  @override
  Future<TextSaveResult> saveText({
    required String text,
    required String filename,
    required String mimeType,
  }) async => pendingSave == null ? saveResult : pendingSave!.future;
  @override
  Future<TextShareResult> shareText({
    required String text,
    required String subject,
  }) async => TextShareResult.unsupported;
}
