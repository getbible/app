import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/grouped_reference_lookup.dart';
import 'package:getbible_live/application/reference_preview_controller.dart';
import 'package:getbible_live/core/errors.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/domain/models/passage.dart';
import 'package:getbible_live/domain/models/reference.dart';
import 'package:getbible_live/domain/repositories/bible_repository.dart';
import 'package:getbible_live/domain/repositories/query_repository.dart';
import 'package:getbible_live/presentation/widgets/reference_preview.dart';
import 'package:getbible_live/presentation/widgets/scripture_verse_text.dart';

void main() {
  testWidgets(
    'preview retains keyboard spacing and draft through inset undershoot',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final ReferencePreviewController controller = _controller(_Query());
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              body: TextButton(
                onPressed: () => unawaited(
                  showAdaptiveReferencePreview(
                    context: context,
                    controller: controller,
                    selectedTranslation: 'kjv',
                    initialRequest: const TextReferenceRequest(
                      translation: 'kjv',
                      reference: 'John 3:16',
                    ),
                    onOpenInReader: (_) async {},
                  ),
                ),
                child: const Text('Show preview'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Show preview'));
      await tester.pumpAndSettle();
      final input = find.byKey(
        const ValueKey<String>('reference-preview-input'),
      );
      await tester.enterText(input, 'John 3:18');
      for (final double inset in <double>[260, 12, -0.25, 0, 180]) {
        tester.view.viewInsets = FakeViewPadding(bottom: inset);
        await tester.pump();
        expect(tester.takeException(), isNull);
        final Padding sheetPadding = tester.widget<Padding>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Padding &&
                widget.child is SizedBox &&
                (widget.child! as SizedBox).child is ReferencePreview,
          ),
        );
        expect(
          sheetPadding.padding,
          EdgeInsets.only(bottom: inset < 0 ? 0 : inset),
        );
        expect(tester.widget<TextField>(input).controller!.text, 'John 3:18');
        expect(tester.testTextInput.isVisible, isTrue);
        expect(
          tester
              .widget<EditableText>(
                find.descendant(of: input, matching: find.byType(EditableText)),
              )
              .focusNode
              .hasFocus,
          isTrue,
        );
        expect(controller.isVisible, isTrue);
      }
      tester.view.viewInsets = const FakeViewPadding();
      await tester.tap(find.byTooltip('Close reference preview'));
      await tester.pumpAndSettle();
      expect(find.byType(ReferencePreview), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('completed Open dismisses its own adaptive route', (
    WidgetTester tester,
  ) async {
    final ReferencePreviewController controller = _controller(_Query());
    addTearDown(controller.dispose);
    Passage? opened;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(
                showAdaptiveReferencePreview(
                  context: context,
                  controller: controller,
                  selectedTranslation: 'kjv',
                  initialRequest: const TextReferenceRequest(
                    translation: 'kjv',
                    reference: 'John 3:16',
                  ),
                  onOpenInReader: (Passage passage) async => opened = passage,
                ),
              ),
              child: const Text('Show preview'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in reader'));
    await tester.pumpAndSettle();
    expect(
      opened,
      const Passage(translation: 'kjv', book: 43, chapter: 3, verse: 16),
    );
    expect(find.byType(ReferencePreview), findsNothing);
    expect(controller.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slow Open after preview close never pops a replacement route', (
    WidgetTester tester,
  ) async {
    final ReferencePreviewController controller = _controller(_Query());
    addTearDown(controller.dispose);
    final Completer<void> pendingOpen = Completer<void>();
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(
                showAdaptiveReferencePreview(
                  context: context,
                  controller: controller,
                  selectedTranslation: 'kjv',
                  initialRequest: const TextReferenceRequest(
                    translation: 'kjv',
                    reference: 'John 3:16',
                  ),
                  onOpenInReader: (_) => pendingOpen.future,
                ),
              ),
              child: const Text('Show preview'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in reader'));
    await tester.pump();
    await tester.tap(find.byTooltip('Close reference preview'));
    await tester.pumpAndSettle();
    unawaited(
      navigator.currentState!.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Replacement route')),
        ),
      ),
    );
    await tester.pumpAndSettle();
    pendingOpen.complete();
    await tester.pumpAndSettle();
    expect(find.text('Replacement route'), findsOneWidget);
    expect(controller.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('slow Open cannot dismiss a newly selected citation', (
    WidgetTester tester,
  ) async {
    final ReferencePreviewController controller = _controller(_Query());
    addTearDown(controller.dispose);
    final Completer<void> pendingOpen = Completer<void>();
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(
                showAdaptiveReferencePreview(
                  context: context,
                  controller: controller,
                  selectedTranslation: 'kjv',
                  initialRequest: const TextReferenceRequest(
                    translation: 'kjv',
                    reference: 'John 3:16',
                  ),
                  onOpenInReader: (_) => pendingOpen.future,
                ),
              ),
              child: const Text('Show preview'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show preview'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Open in reader'));
    await tester.pump();
    await controller.open(
      const TextReferenceRequest(translation: 'kjv', reference: 'John 3:18'),
    );
    await tester.pumpAndSettle();
    pendingOpen.complete();
    await tester.pumpAndSettle();
    expect(find.byType(ReferencePreview), findsOneWidget);
    expect(controller.request!.label, 'John 3:18');
    await tester.tap(find.byTooltip('Close reference preview'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'compact metadata uses selected translation direction and input errors stay distinct from offline',
    (WidgetTester tester) async {
      final _Query query = _Query();
      final ReferencePreviewController controller = _controller(query);
      addTearDown(controller.dispose);
      await controller.open(
        const TextReferenceRequest(
          translation: 'kjv',
          reference: 'John 3:16',
          translationDirection: 'RTL',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReferencePreview(
              controller: controller,
              selectedTranslation: 'kjv',
              onOpenInReader: (_) async {},
              onClose: controller.close,
            ),
          ),
        ),
      );
      expect(
        Directionality.of(
          tester.element(find.byType(ScriptureVerseText).first),
        ),
        TextDirection.rtl,
      );
      query.response = () async => throw InvalidApiRequestException(
        statusCode: 400,
        uri: Uri.parse('https://query.getbible.net/v3/kjv/reference'),
      );
      await controller.open(
        const TextReferenceRequest(translation: 'kjv', reference: 'Too broad'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text('GetBible could not accept the requested input.'),
        findsOneWidget,
      );
      expect(find.textContaining('Check your connection'), findsNothing);
    },
  );

  testWidgets('typed reference input retains the selected translation', (
    WidgetTester tester,
  ) async {
    final _Query query = _Query();
    final ReferencePreviewController controller = _controller(query);
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReferencePreview(
            controller: controller,
            selectedTranslation: 'selected',
            onOpenInReader: (_) async {},
            onClose: controller.close,
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('reference-preview-input')),
      'John 3:16',
    );
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(controller.request!.translation, 'selected');
    expect(controller.result!.translation, 'selected');
    expect(controller.result!.requestedReferences, <String>['John 3:16']);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'preview retains text and reference, copies, and opens the exact selected verse',
    (WidgetTester tester) async {
      final _Query query = _Query();
      final ReferencePreviewController controller = _controller(query);
      addTearDown(controller.dispose);
      const Passage readerPosition = Passage(
        translation: 'kjv',
        book: 1,
        chapter: 1,
        verse: 1,
      );
      Passage position = readerPosition;
      String? copied;
      final Completer<void> copyAcknowledged = Completer<void>();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, (
            MethodCall method,
          ) async {
            if (method.method == 'Clipboard.setData') {
              copied =
                  (method.arguments as Map<Object?, Object?>)['text']!
                      as String;
              await copyAcknowledged.future;
            }
            return null;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(SystemChannels.platform, null),
      );
      await controller.open(
        const TextReferenceRequest(
          translation: 'kjv',
          translationName: 'King James Version',
          reference: 'John 3:16,18',
          sourceLabel: 'Johannes 3:16,18',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReferencePreview(
              controller: controller,
              selectedTranslation: 'kjv',
              onOpenInReader: (Passage passage) async => position = passage,
              onClose: controller.close,
            ),
          ),
        ),
      );
      expect(position, readerPosition);
      expect(find.text('King James Version'), findsOneWidget);
      expect(find.text('Johannes 3:16,18'), findsOneWidget);
      expect(
        find.text('  Exact\nScripture 😀  ', findRichText: true),
        findsOneWidget,
      );
      await tester.tap(find.text('Copy'));
      await tester.pump();
      expect(copied, contains('  Exact\nScripture 😀  '));
      expect(find.text('Scripture copied'), findsNothing);
      copyAcknowledged.complete();
      await tester.pumpAndSettle();
      expect(find.text('Scripture copied'), findsOneWidget);
      await tester.tap(find.byTooltip('Open in reader: 18'));
      await tester.pump();
      expect(
        position,
        const Passage(translation: 'kjv', book: 43, chapter: 3, verse: 18),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('loading, unavailable reference and retry are visible', (
    WidgetTester tester,
  ) async {
    final Completer<ReferenceResult> pending = Completer<ReferenceResult>();
    final _Query query = _Query()..response = () => pending.future;
    final ReferencePreviewController controller = _controller(query);
    addTearDown(controller.dispose);
    final Future<void> load = controller.open(
      const TextReferenceRequest(
        translation: 'kjv',
        reference: 'Unresolved reference',
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ReferencePreview(
            controller: controller,
            selectedTranslation: 'kjv',
            onOpenInReader: (_) async {},
            onClose: controller.close,
          ),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    pending.completeError(
      ResourceUnavailableException(
        Uri.parse('https://query.getbible.net/v3/kjv/missing'),
      ),
    );
    await load;
    await tester.pump();
    expect(
      find.text('This reference or translation is unavailable.'),
      findsOneWidget,
    );
    expect(find.text('Copy'), findsNothing);
    query.response = null;
    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();
    expect(find.text('Copy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed Open remains reviewable and does not escape as an unhandled future',
    (WidgetTester tester) async {
      final ReferencePreviewController controller = _controller(_Query());
      addTearDown(controller.dispose);
      await controller.open(
        const TextReferenceRequest(translation: 'kjv', reference: 'John 3:16'),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ReferencePreview(
              controller: controller,
              selectedTranslation: 'kjv',
              onOpenInReader: (_) async =>
                  throw const NetworkException('Chapter could not be opened.'),
              onClose: controller.close,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open in reader'));
      await tester.pumpAndSettle();
      expect(find.text('Chapter could not be opened.'), findsOneWidget);
      expect(controller.result, isNotNull);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'compact large-text layout keeps content and controls inside its bounds',
    (WidgetTester tester) async {
      final ReferencePreviewController controller = _controller(_Query());
      addTearDown(controller.dispose);
      await controller.open(
        const TextReferenceRequest(
          translation: 'kjv',
          reference: 'John 3:16,18',
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(280, 760),
              textScaler: TextScaler.linear(2),
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: 280,
                  height: 760,
                  child: ReferencePreview(
                    controller: controller,
                    selectedTranslation: 'kjv',
                    onOpenInReader: (_) async {},
                    onClose: controller.close,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.byType(ReferencePreview), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'adaptive compact route closes without changing the reader scroll or position',
    (WidgetTester tester) async {
      tester.view.physicalSize = const Size(600, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final ScrollController scroll = ScrollController(
        initialScrollOffset: 350,
      );
      addTearDown(scroll.dispose);
      final FocusNode readerFocus = FocusNode();
      addTearDown(readerFocus.dispose);
      final ReferencePreviewController controller = _controller(_Query());
      addTearDown(controller.dispose);
      const Passage position = Passage(
        translation: 'kjv',
        book: 1,
        chapter: 1,
        verse: 1,
      );
      Passage opened = position;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) => Scaffold(
              floatingActionButton: FloatingActionButton(
                focusNode: readerFocus,
                onPressed: () => unawaited(
                  showAdaptiveReferencePreview(
                    context: context,
                    controller: controller,
                    selectedTranslation: 'kjv',
                    initialRequest: const TextReferenceRequest(
                      translation: 'kjv',
                      reference: 'John 3:16',
                    ),
                    onOpenInReader: (Passage passage) async => opened = passage,
                  ),
                ),
                child: const Icon(Icons.search),
              ),
              body: ListView(
                controller: scroll,
                children: List<Widget>.generate(
                  100,
                  (int index) =>
                      SizedBox(height: 60, child: Text('Reader verse $index')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      readerFocus.requestFocus();
      await tester.pump();
      expect(readerFocus.hasFocus, isTrue);
      final double offset = scroll.offset;
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      expect(find.byType(BottomSheet), findsOneWidget);
      expect(opened, position);
      await tester.tap(find.byTooltip('Close reference preview'));
      await tester.pumpAndSettle();
      expect(controller.isVisible, isFalse);
      expect(controller.historyLength, 0);
      expect(scroll.offset, offset);
      expect(readerFocus.hasFocus, isTrue);
      expect(opened, position);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('wide preview shares one panel for subsequent citations', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final ReferencePreviewController controller = _controller(_Query());
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (BuildContext context) => Scaffold(
            body: TextButton(
              onPressed: () => unawaited(
                showAdaptiveReferencePreview(
                  context: context,
                  controller: controller,
                  selectedTranslation: 'kjv',
                  onOpenInReader: (_) async {},
                  initialRequest: const TextReferenceRequest(
                    translation: 'kjv',
                    reference: 'John 3:16',
                  ),
                ),
              ),
              child: const Text('Show preview'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Show preview'));
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byType(BottomSheet), findsNothing);
    await controller.open(
      const TextReferenceRequest(translation: 'kjv', reference: 'John 3:18'),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    expect(find.byTooltip('Previous citation'), findsOneWidget);
    await tester.tap(find.byTooltip('Close reference preview'));
    await tester.pumpAndSettle();
    expect(controller.isVisible, isFalse);
    expect(tester.takeException(), isNull);
  });
}

ReferencePreviewController _controller(_Query query) =>
    ReferencePreviewController(
      lookup: GroupedReferenceLookup(
        queryRepository: query,
        bibleRepository: _Bible(),
      ),
    );

class _Bible extends Fake implements BibleRepository {}

class _Query implements QueryRepository {
  Future<ReferenceResult> Function()? response;

  @override
  Future<ReferenceResult> query(
    String translation,
    String reference, {
    RequestCancellation? cancellation,
  }) async => response == null
      ? ReferenceResult.fromJson(
          <String, Object?>{
            '${translation}_43_3': <String, Object?>{
              'book_nr': 43,
              'book_name': 'John',
              'chapter': 3,
              'ref': <String>['John 3:16,18'],
              'verses': <Object?>[
                <String, Object?>{
                  'verse': 16,
                  'name': 'John 3:16',
                  'text': '  Exact\nScripture 😀  ',
                },
                <String, Object?>{
                  'verse': 18,
                  'name': 'John 3:18',
                  'text': 'Another verse.',
                },
              ],
            },
          },
          translation: translation,
          reference: reference,
        )
      : await response!();
}
