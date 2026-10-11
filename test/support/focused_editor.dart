import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Reveals a retained editor after native keyboard geometry has settled.
///
/// [WidgetTester.pumpAndSettle] observes Flutter's scheduled frames, but a native
/// IME can deliver new viewport metrics after those frames finish. Wait for the
/// relevant geometry to stop changing before revealing the complete form field.
/// Do not wait for a successful hit test: callers still assert accessibility,
/// focus and editability independently after this bounded synchronization.
Future<void> revealFocusedEditor(
  WidgetTester tester, {
  required EditableTextState editor,
  Duration quietPeriod = const Duration(milliseconds: 500),
  Duration timeout = const Duration(seconds: 5),
}) async {
  if (!editor.mounted) {
    throw TestFailure(
      'The focused editor was disposed before keyboard layout.',
    );
  }
  // A lazy list can retain its focused editor outside the painted viewport.
  // Normal finders skip those children; use the retained editor's ancestry
  // until the containing form field has actually been revealed.
  final FormFieldState<String>? formField = editor.context
      .findAncestorStateOfType<FormFieldState<String>>();
  if (formField == null) {
    throw TestFailure('The focused editor has no containing text form field.');
  }
  final BuildContext fieldContext = formField.context;
  final DateTime deadline = tester.binding.clock.fromNowBy(timeout);

  Future<void> waitForGeometry() async {
    Object? previous;
    DateTime? unchangedSince;
    while (true) {
      if (!editor.mounted || !fieldContext.mounted) {
        throw TestFailure(
          'The focused editor was disposed during keyboard layout.',
        );
      }
      final ScrollPosition position = Scrollable.of(fieldContext).position;
      final RenderBox editableBox =
          editor.context.findRenderObject()! as RenderBox;
      final RenderBox fieldBox = fieldContext.findRenderObject()! as RenderBox;
      final geometry = (
        physicalSize: tester.view.physicalSize,
        devicePixelRatio: tester.view.devicePixelRatio,
        insets: (
          tester.view.viewInsets.left,
          tester.view.viewInsets.top,
          tester.view.viewInsets.right,
          tester.view.viewInsets.bottom,
        ),
        field: fieldBox.localToGlobal(Offset.zero) & fieldBox.size,
        editable: editableBox.localToGlobal(Offset.zero) & editableBox.size,
        scrollOffset: position.pixels,
        viewport: position.viewportDimension,
        scrolling: position.isScrollingNotifier.value,
      );
      final DateTime now = tester.binding.clock.now();
      if (geometry != previous || geometry.scrolling) {
        previous = geometry;
        unchangedSince = now;
      }
      if (now.isAfter(deadline)) {
        throw TestFailure(
          'Keyboard/editor geometry did not settle within $timeout. '
          'Last geometry: $geometry; focused: ${editor.widget.focusNode.hasFocus}.',
        );
      }
      if (!geometry.scrolling &&
          unchangedSince != null &&
          now.difference(unchangedSince) >= quietPeriod) {
        return;
      }
      if (tester.binding is LiveTestWidgetsFlutterBinding) {
        // Live platform messages need real event-loop time, not only simulated
        // frames. A hardware keyboard can legitimately leave the inset at zero.
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      } else {
        await tester.pump(const Duration(milliseconds: 50));
      }
    }
  }

  await waitForGeometry();
  // Match the caller's TextFormField hit-test boundary, rather than revealing
  // only the smaller inner EditableText rectangle above its label/counter.
  await Scrollable.ensureVisible(fieldContext, alignment: .5);
  await waitForGeometry();
}
