import 'package:flutter/material.dart';

/// A complete installation is distinct from an opportunistically cached page.
final class StudyOfflineStatus extends StatelessWidget {
  const StudyOfflineStatus({
    required this.installed,
    this.onSetUpOffline,
    super.key,
  });
  final bool? installed;
  final VoidCallback? onSetUpOffline;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (installed != null)
          Text(
            installed!
                ? 'Installed on this device · available offline'
                : 'Online resource · not installed on this device',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        if (onSetUpOffline != null)
          TextButton.icon(
            onPressed: onSetUpOffline,
            icon: const Icon(Icons.download_outlined),
            label: const Text('Set up offline use'),
          ),
      ],
    ),
  );
}
