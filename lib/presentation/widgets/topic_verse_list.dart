import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../application/grouped_reference_lookup.dart';
import '../../application/topic_verse_loader.dart';
import '../../core/errors.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/passage.dart';
import '../../domain/models/preferences.dart';
import '../../domain/models/reference.dart';
import 'scripture_verse_text.dart';

/// View-only topic membership metadata. A fetched verse never replaces a saved
/// quote or changes the independent personal/global membership records.
final class TopicVerseItem {
  const TopicVerseItem({
    required this.passage,
    required this.reference,
    this.global = false,
    this.personal = false,
    this.selectedQuote,
    this.quoteTranslation,
  });
  final Passage passage;
  final String reference;
  final bool global, personal;
  final String? selectedQuote, quoteTranslation;
}

/// A bounded, native Scripture list shared by saved topics and public browsing.
/// Revealing another page is deliberate; simply opening a large topic never
/// fetches its entire collection. Each row can fail/retry independently.
class TopicVerseList extends StatefulWidget {
  const TopicVerseList({
    super.key,
    required this.lookup,
    required this.items,
    required this.onOpen,
    this.actionsBuilder,
    this.scriptureStyle,
    this.preferences,
    this.showSourceStyles = true,
  });
  final GroupedReferenceLookup lookup;
  final List<TopicVerseItem> items;
  final ValueChanged<TopicVerseItem> onOpen;
  final List<Widget> Function(TopicVerseItem item, int index)? actionsBuilder;
  final TextStyle? scriptureStyle;
  final ReaderPreferences? preferences;
  final bool showSourceStyles;

  @override
  State<TopicVerseList> createState() => _TopicVerseListState();
}

class _TopicVerseListState extends State<TopicVerseList> {
  late TopicVerseLoader _loader;
  List<Passage> get _passages =>
      widget.items.map((item) => item.passage).toList();

  @override
  void initState() {
    super.initState();
    _loader = TopicVerseLoader(lookup: widget.lookup);
    unawaited(_loader.open(_passages));
  }

  @override
  void didUpdateWidget(TopicVerseList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.lookup != widget.lookup) {
      _loader.dispose();
      _loader = TopicVerseLoader(lookup: widget.lookup);
      unawaited(_loader.open(_passages));
    } else if (!listEquals(
      oldWidget.items.map((item) => item.passage).toList(),
      _passages,
    )) {
      unawaited(_loader.open(_passages));
    }
  }

  @override
  void dispose() {
    _loader.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _loader,
    builder: (context, _) => SliverList.builder(
      itemCount: _loader.visibleCount + (_loader.hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index == _loader.visibleCount) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: OutlinedButton.icon(
              onPressed: _loader.loadingPage
                  ? null
                  : () => unawaited(_loader.loadMore()),
              icon: const Icon(Icons.expand_more),
              label: Text(UiStrings.of(context).text('Show more verses')),
            ),
          );
        }
        return _card(widget.items[index], index);
      },
    ),
  );

  Widget _card(TopicVerseItem item, int index) {
    final strings = UiStrings.of(context);
    final text = _loader.textFor(item.passage);
    final error = _loader.errorFor(item.passage);
    final loading = _loader.isLoading(item.passage);
    final translation = item.passage.translation.toUpperCase();
    return Card(
      key: ValueKey(
        'topic-verse:${item.passage.key}/${item.passage.verse}:$index',
      ),
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 4,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                TextButton(
                  onPressed: () => widget.onOpen(item),
                  style: TextButton.styleFrom(
                    alignment: AlignmentDirectional.centerStart,
                  ),
                  child: Text(
                    '${text?.reference ?? item.reference} · $translation',
                  ),
                ),
                if (item.global)
                  Tooltip(
                    message: strings.text(
                      item.personal
                          ? 'Global and personal bookmark'
                          : 'Global bookmark',
                    ),
                    child: Semantics(
                      label: strings.text(
                        item.personal
                            ? 'Global and personal bookmark'
                            : 'Global bookmark',
                      ),
                      child: ExcludeSemantics(
                        child: Chip(
                          label: Text(strings.text('G')),
                          visualDensity: VisualDensity.compact,
                        ),
                      ),
                    ),
                  ),
                ...?widget.actionsBuilder?.call(item, index),
              ],
            ),
            if (text != null)
              ScriptureVerseText(
                verse: text.verse,
                passage: item.passage,
                style:
                    widget.scriptureStyle ??
                    Theme.of(context).textTheme.bodyLarge!.copyWith(
                      fontSize: widget.preferences?.textSize,
                      height: 1.45,
                      fontFamily: switch (widget.preferences?.readerFont) {
                        'serif' => 'serif',
                        'book' => 'Georgia',
                        'baskerville' => 'Baskerville',
                        'garamond' => 'Garamond',
                        'charter' => 'Charter',
                        'cambria' => 'Cambria',
                        'times' => 'Times New Roman',
                        'sans' => 'Arial',
                        _ => null,
                      },
                    ),
                textDirection: text.chapter.direction.toUpperCase() == 'RTL'
                    ? TextDirection.rtl
                    : TextDirection.ltr,
                showSourceStyles:
                    widget.preferences?.showSourceStyles ??
                    widget.showSourceStyles,
              )
            else if (loading)
              Semantics(
                liveRegion: true,
                child: Text(strings.text('Loading verse…')),
              )
            else if (error != null) ...[
              Text(
                error is ReferenceLookupException ||
                        error is ResourceUnavailableException
                    ? strings.text(
                        'This verse is unavailable in the selected Bible.',
                      )
                    : strings.text('Could not load this verse. Try again.'),
              ),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _loader.loadingPage
                      ? null
                      : () => unawaited(_loader.retry(item.passage)),
                  icon: const Icon(Icons.refresh),
                  label: Text(strings.text('Retry')),
                ),
              ),
            ],
            if (item.selectedQuote?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              Text(
                strings.text('Saved selection · {translation}', {
                  'translation':
                      (item.quoteTranslation ?? item.passage.translation)
                          .toUpperCase(),
                }),
                style: Theme.of(context).textTheme.labelMedium,
              ),
              SelectableText(item.selectedQuote!),
            ],
          ],
        ),
      ),
    );
  }
}
