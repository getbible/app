import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/product_identity.dart';
import '../../core/ui_strings.dart';

/// Attribution at the end of translation licensing information.
/// It opens documentation, never an API data response or reader route.
class InfrastructureCredit extends StatelessWidget {
  const InfrastructureCredit({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: const ValueKey('translation-infrastructure-credit'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border.all(color: theme.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ExcludeSemantics(
            child: Image.asset(
              'assets/branding/getbible_book.png',
              width: 48,
              height: 60,
              fit: BoxFit.contain,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  UiStrings.of(context).text('The Word for the world!'),
                  style: theme.textTheme.titleSmall,
                ),
                TextButton(
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    alignment: AlignmentDirectional.centerStart,
                  ),
                  onPressed: () => launchUrl(ProductIdentity.documentationUri),
                  child: Text(
                    UiStrings.of(context).text('Powered by {getBible} APIs.', {
                      'getBible': ProductIdentity.name,
                    }),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
