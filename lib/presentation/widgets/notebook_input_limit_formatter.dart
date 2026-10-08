import 'package:flutter/services.dart';

/// Uses the same units as the private document contract. Flutter's built-in
/// maxLength counts graphemes, which cannot enforce rune or UTF-16 bounds.
/// Rejecting a whole overflowing edit preserves the accepted text and caret;
/// truncation could otherwise delete an existing suffix when typing mid-field.
final class NotebookInputLimitFormatter extends TextInputFormatter {
  NotebookInputLimitFormatter({
    required this.codeUnitCapacity,
    required this.onLimit,
    this.maxRunes,
  });
  final int Function() codeUnitCapacity;
  final int? maxRunes;
  final void Function() onLimit;
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    if (newValue.text.length > codeUnitCapacity() ||
        (maxRunes != null && newValue.text.runes.length > maxRunes!)) {
      onLimit();
      return oldValue;
    }
    return newValue;
  }
}
