import 'package:flutter/material.dart';

import '../../domain/models/cache.dart';

/// A quiet, inspectable status indicator for the current chapter cache.
class ScriptureVerificationBadge extends StatelessWidget {
  const ScriptureVerificationBadge({super.key, required this.freshness});

  final CacheFreshness freshness;

  bool get _verified => freshness != CacheFreshness.cachedUnverified;

  @override
  Widget build(BuildContext context) {
    final String label = _verified ? 'Verified Scripture' : 'Saved Scripture';
    return Semantics(
      button: true,
      label: '$label. Show verification details.',
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
        tooltip: label,
        onPressed: () => _showDetails(context),
        icon: Icon(
          _verified ? Icons.verified_user_outlined : Icons.cloud_off_outlined,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Future<void> _showDetails(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        icon: Icon(
          _verified ? Icons.verified_user_outlined : Icons.cloud_off_outlined,
        ),
        title: Text(
          _verified ? 'Scripture verified' : 'Saved for offline reading',
        ),
        content: Text(
          _verified
              ? 'This chapter was checked against the hash published by GetBible and matches the current source.'
              : 'This is the last known good copy saved on this device. It remains readable offline, but the current source hash could not be checked.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}
