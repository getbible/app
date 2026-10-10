import 'package:flutter/material.dart';

import '../../core/ui_strings.dart';

/// A complete installation is distinct from an opportunistically cached page.
final class StudyOfflineStatus extends StatelessWidget {
  const StudyOfflineStatus({
    required this.installed,
    this.onManageDownloads,
    super.key,
  });
  final bool? installed;
  final VoidCallback? onManageDownloads;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (installed != null)
          Text(
            installed!
                ? UiStrings.of(
                    context,
                  ).text('Installed on this device · available offline')
                : UiStrings.of(context).text('Not yet available offline'),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (onManageDownloads != null)
          TextButton.icon(
            onPressed: onManageDownloads,
            icon: const Icon(Icons.download_outlined),
            label: Text(UiStrings.of(context).text('Downloads & storage')),
          ),
      ],
    ),
  );
}
