import 'dart:math' as math;

import 'package:flutter/widgets.dart';

/// Keeps sheet content above the keyboard without treating an animation
/// undershoot as negative layout padding.
///
/// The pinned Flutter iOS embedder forwards its keyboard spring curve directly
/// to the bottom view inset. A negative value cannot obscure any content, but
/// passing it to [Padding] breaks layout during keyboard dismissal. Preserve
/// every positive inset and normalize only that negative occlusion boundary.
class KeyboardInsetPadding extends StatelessWidget {
  const KeyboardInsetPadding({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.only(
      bottom: math.max(0, MediaQuery.viewInsetsOf(context).bottom),
    ),
    child: child,
  );
}
