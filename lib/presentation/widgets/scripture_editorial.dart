import 'package:flutter/material.dart';

import '../../domain/models/bible.dart';

/// Editorial headings retain their own source text and do not join verse text.
class ScriptureEditorialHeading extends StatelessWidget {
  const ScriptureEditorialHeading({
    super.key,
    required this.heading,
    required this.textStyle,
    this.textDirection,
  });

  final EditorialHeading heading;
  final TextStyle textStyle;
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Padding(
      padding: const EdgeInsetsDirectional.only(top: 18, bottom: 10, start: 4),
      child: SelectableText(
        heading.text,
        textDirection: textDirection,
        style: textStyle.copyWith(fontWeight: FontWeight.w600, height: 1.4),
      ),
    ),
  );
}

/// Natural-level prose is displayed separately, with no invented verse numbers.
class ScriptureIntroductionSection extends StatelessWidget {
  const ScriptureIntroductionSection({
    super.key,
    this.titles = const <ScriptureTitle>[],
    this.introduction = const <ScriptureIntroduction>[],
    required this.textStyle,
    this.textDirection,
  });

  final List<ScriptureTitle> titles;
  final List<ScriptureIntroduction> introduction;
  final TextStyle textStyle;
  final TextDirection? textDirection;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (final ScriptureTitle title in titles)
        Semantics(
          header: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: SelectableText(
              title.text,
              textDirection: textDirection,
              style: textStyle.copyWith(fontWeight: FontWeight.w600),
            ),
          ),
        ),
      for (final ScriptureIntroduction item in introduction)
        Padding(
          padding: const EdgeInsets.only(bottom: 14),
          child: SelectableText(
            item.text,
            textDirection: textDirection,
            style: textStyle.copyWith(height: 1.5),
          ),
        ),
    ],
  );
}
