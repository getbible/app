import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/focused_editor.dart';
import 'support/study_workspace_journey.dart';

void main() {
  // A real keyboard can still be closing when Study opens after native text
  // input. Source metadata must be checked independently of list visibility,
  // then reached through the same scroll interaction available to a user.
  // Later, its show notification arrives between scrolling from the notebook
  // title to its body and focusing that editor. The body must remain editable,
  // and both fields must survive closing and reopening Study while offline.
  studyWorkspaceJourney(
    viewport: const Size(1280, 900),
    platform: TargetPlatformVariant.only(TargetPlatform.android),
    initialKeyboardInset: 420,
    notebookKeyboardInset: 420,
  );

  testWidgets('editor reveal waits for delayed native keyboard geometry', (
    tester,
  ) async {
    final (field, editor) = await mountFocusedEditor(tester);
    // Flutter currently has no pending frames. The native IME's first viewport
    // notification can nevertheless arrive later, shrinking the scrollable.
    await tester.pumpAndSettle();
    expect(tester.binding.hasScheduledFrame, isFalse);
    var delivered = false;
    final timer = Timer(const Duration(milliseconds: 200), () {
      delivered = true;
      tester.view.viewInsets = const FakeViewPadding(bottom: 550);
    });
    try {
      await revealFocusedEditor(tester, editor: editor);
    } finally {
      timer.cancel();
    }

    expect(delivered, isTrue);
    expect(tester.view.viewInsets.bottom, 550);
    expect(editor.mounted, isTrue);
    expect(editor.widget.focusNode.hasFocus, isTrue);
    expect(field.hitTestable(), findsOneWidget);
    await tester.enterText(field, 'Editable after delayed keyboard layout.');
    expect(
      editor.widget.controller.text,
      'Editable after delayed keyboard layout.',
    );
  });

  testWidgets('editor reveal also supports a keyboard with zero inset', (
    tester,
  ) async {
    final (field, editor) = await mountFocusedEditor(tester);
    await revealFocusedEditor(tester, editor: editor);
    expect(tester.view.viewInsets.bottom, 0);
    expect(editor.mounted, isTrue);
    expect(editor.widget.focusNode.hasFocus, isTrue);
    expect(field.hitTestable(), findsOneWidget);
  });

  testWidgets('unstable keyboard geometry fails within its deadline', (
    tester,
  ) async {
    final (_, editor) = await mountFocusedEditor(tester);
    final timer = Timer.periodic(const Duration(milliseconds: 100), (timer) {
      tester.view.viewInsets = FakeViewPadding(
        bottom: timer.tick.isEven ? 200 : 250,
      );
    });
    TestFailure? failure;
    try {
      await revealFocusedEditor(
        tester,
        editor: editor,
        timeout: const Duration(milliseconds: 600),
      );
    } on TestFailure catch (error) {
      failure = error;
    } finally {
      timer.cancel();
    }
    expect(failure, isNotNull);
    expect(failure!.message, contains('Last geometry:'));
  });
}

Future<(Finder, EditableTextState)> mountFocusedEditor(
  WidgetTester tester,
) async {
  tester.view.physicalSize = const Size(800, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            const SizedBox(height: 600),
            TextFormField(
              minLines: 3,
              maxLines: null,
              decoration: const InputDecoration(
                labelText: 'Study or sermon notes',
                counterText: '0 / 1000',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 400),
          ],
        ),
      ),
    ),
  );
  final field = find.widgetWithText(TextFormField, 'Study or sermon notes');
  await tester.ensureVisible(field);
  await tester.showKeyboard(field);
  await tester.pumpAndSettle();
  final editor = tester.state<EditableTextState>(
    find.descendant(of: field, matching: find.byType(EditableText)),
  );
  return (field, editor);
}
