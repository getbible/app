import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/ui_strings.dart';
import '../../domain/models/cache.dart';

/// A quiet, inspectable status indicator for the current chapter cache.
class ScriptureVerificationBadge extends StatelessWidget {
  const ScriptureVerificationBadge({super.key, required this.freshness});

  final CacheFreshness freshness;

  bool get _verified => freshness != CacheFreshness.cachedUnverified;

  @override
  Widget build(BuildContext context) {
    final String label = _verified
        ? UiStrings.of(context).text('Verified Scripture')
        : UiStrings.of(context).text('Saved Scripture');
    return Semantics(
      button: true,
      label: UiStrings.of(
        context,
      ).text('{label}. Show verification details.', {'label': label}),
      child: IconButton(
        visualDensity: VisualDensity.compact,
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
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
          _verified
              ? UiStrings.of(context).text('Scripture verified')
              : UiStrings.of(context).text('Saved for offline reading'),
        ),
        content: Text(
          _verified
              ? UiStrings.of(context).text(
                  'This chapter was checked against the hash published by GetBible and matches the current source.',
                )
              : UiStrings.of(context).text(
                  'This is the last known good copy saved on this device. It remains readable offline, but the current source hash could not be checked.',
                ),
        ),
        actions: <Widget>[
          TextButton.icon(
            onPressed: () =>
                launchUrl(Uri.parse('https://getbible.net/api/bible/')),
            icon: const Icon(Icons.open_in_new),
            label: const Text('GetBible API'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(UiStrings.of(context).text('Close')),
          ),
        ],
      ),
    );
  }
}
