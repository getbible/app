import 'package:flutter/material.dart';

import '../../domain/models/bible.dart';

/// A width-safe translation selector for drawers and compact reader surfaces.
class ReaderTranslationField extends StatelessWidget {
  const ReaderTranslationField({
    super.key,
    required this.translations,
    required this.value,
    required this.onChanged,
  });

  final List<Translation> translations;
  final String value;
  final ValueChanged<String?>? onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<String>(
      initialValue: value,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'Translation'),
      selectedItemBuilder: (BuildContext context) => translations
          .map(
            (Translation item) => Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                item.translation,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(growable: false),
      items: translations
          .map(
            (Translation item) => DropdownMenuItem<String>(
              value: item.abbreviation,
              child: Text(
                item.translation,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          )
          .toList(growable: false),
      onChanged: onChanged,
    );
  }
}
