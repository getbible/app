import 'package:flutter/material.dart';

import '../../core/ui_strings.dart';
import '../../domain/models/bible.dart';
import '../../services/source_annotations.dart';

/// Native source notes below Scripture, outside its selection document.
class ScriptureSourceAnnotations extends StatelessWidget {
  const ScriptureSourceAnnotations({
    super.key,
    required this.verse,
    this.onReference,
  });
  final Verse verse;
  final ValueChanged<String>? onReference;

  @override
  Widget build(BuildContext context) {
    final ui = UiStrings.of(context);
    final annotations = verseSourceAnnotations(verse, localizeLabel: ui.text);
    if (annotations.isEmpty) return const SizedBox.shrink();
    // Whole-verse bookmarks may paint a ColoredBox above this surface. Keep
    // native expansion and citation ink visible without covering that marking.
    return Material(
      type: MaterialType.transparency,
      child: Padding(
        padding: const EdgeInsetsDirectional.only(start: 12, top: 4, bottom: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final annotation in annotations)
              ExpansionTile(
                // A PageStorageKey would also become the nested SelectableText
                // scroll position's key, mixing an expansion bool with a double.
                key: ValueKey(
                  '${verse.chapter}:${verse.verse}:${annotation.id}',
                ),
                tilePadding: EdgeInsets.zero,
                title: Text(annotation.label),
                subtitle: annotation.text.isEmpty
                    ? null
                    : Text(
                        annotation.text,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                childrenPadding: const EdgeInsetsDirectional.only(
                  start: 8,
                  bottom: 8,
                ),
                expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (annotation.text.isNotEmpty)
                    SelectableText(annotation.text),
                  for (final detail in annotation.details)
                    SelectableText(detail),
                  if (annotation.references.isNotEmpty)
                    Wrap(
                      spacing: 8,
                      children: [
                        for (final reference in annotation.references)
                          TextButton.icon(
                            onPressed: onReference == null
                                ? null
                                : () => onReference!(reference),
                            icon: const Icon(Icons.find_in_page_outlined),
                            label: Text(reference),
                          ),
                      ],
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}
