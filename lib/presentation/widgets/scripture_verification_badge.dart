import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/product_identity.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/cache.dart';

/// The chapter's cache status. Its owner places the explanation in the reader
/// flow so opening it never covers Scripture or creates a modal focus trap.
class ScriptureVerificationBadge extends StatelessWidget {
  const ScriptureVerificationBadge({
    super.key,
    required this.freshness,
    required this.onPressed,
    this.expanded = false,
  });

  final CacheFreshness freshness;
  final VoidCallback onPressed;
  final bool expanded;

  @override
  Widget build(BuildContext context) {
    final verified = freshness != CacheFreshness.cachedUnverified;
    final strings = UiStrings.of(context);
    final label = verified
        ? strings.text('Verified Scripture')
        : strings.text('Saved Scripture');
    // Keep the expanded state on the native button's single accessibility node.
    // A separate outer button/label creates a second, inert browser button.
    return MergeSemantics(
      child: Semantics(
        expanded: expanded,
        child: IconButton(
          constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          tooltip: label,
          onPressed: onPressed,
          icon: Icon(
            verified ? Icons.verified_user_outlined : Icons.cloud_off_outlined,
            size: 18,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

/// A small, wrapping notice directly beneath the chapter heading.
class ScriptureVerificationNotice extends StatelessWidget {
  const ScriptureVerificationNotice({
    super.key,
    required this.freshness,
    required this.onClose,
  });

  final CacheFreshness freshness;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final verified = freshness != CacheFreshness.cachedUnverified;
    final theme = Theme.of(context);
    return Semantics(
      liveRegion: true,
      child: Container(
        key: const ValueKey('scripture-verification-notice'),
        margin: const EdgeInsetsDirectional.fromSTEB(20, 0, 20, 8),
        padding: const EdgeInsetsDirectional.only(start: 12),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerLow,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(
                      verified
                          ? UiStrings.of(context).text(
                              'This chapter was checked against the hash published by getBible and matches the current source.',
                            )
                          : UiStrings.of(context).text(
                              'This is the last known good copy saved on this device. It remains readable offline, but the current source hash could not be checked.',
                            ),
                      style: theme.textTheme.bodySmall,
                    ),
                    TextButton(
                      onPressed: () =>
                          launchUrl(ProductIdentity.bibleApiDocumentationUri),
                      child: const Text('getBible API'),
                    ),
                  ],
                ),
              ),
            ),
            IconButton(
              onPressed: onClose,
              tooltip: UiStrings.of(
                context,
              ).text('Close verification explanation'),
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}
