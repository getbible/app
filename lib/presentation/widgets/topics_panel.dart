import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/grouped_reference_lookup.dart';
import '../../application/topics_controller.dart';
import '../../application/unified_bookmarks_controller.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/passage.dart';
import '../../domain/models/preferences.dart';
import '../../domain/models/public_topic.dart';
import '../../domain/models/reference.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/models/study_context.dart';
import 'study_offline_status.dart';
import 'topic_verse_list.dart';

/// Native public-topic browsing with bounded inline selected-Bible Scripture.
/// Following/hiding and reading text never create private annotations.
final class TopicsPanel extends StatefulWidget {
  const TopicsPanel({
    super.key,
    required this.controller,
    required this.context,
    required this.onPreviewReference,
    this.onManageDownloads,
    this.onPrivateCopyCommitted,
    this.bookmarks,
    this.onOpenBookmarks,
    this.referenceLookup,
    this.preferences,
  });

  final TopicsController controller;
  final GroupedReferenceLookup? referenceLookup;
  final ReaderPreferences? preferences;
  final UnifiedBookmarksController? bookmarks;
  final ValueChanged<String?>? onOpenBookmarks;
  final StudyContext context;
  final Future<void> Function(ReferenceRequest) onPreviewReference;
  final VoidCallback? onManageDownloads;
  final Future<void> Function()? onPrivateCopyCommitted;

  @override
  State<TopicsPanel> createState() => _TopicsPanelState();
}

final class _TopicsPanelState extends State<TopicsPanel> {
  final TextEditingController _search = TextEditingController();
  bool _onlyRelated = false;
  bool _onlyFollowed = false;
  bool _showHidden = false;

  @override
  void initState() {
    super.initState();
    unawaited(widget.controller.initialize(widget.context));
  }

  @override
  void didUpdateWidget(TopicsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.context != widget.context ||
        oldWidget.controller != widget.controller) {
      oldWidget.controller.dismiss();
      unawaited(widget.controller.initialize(widget.context));
    }
  }

  @override
  void dispose() {
    _search.dispose();
    widget.controller.dismiss();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: Listenable.merge([
      widget.controller,
      if (widget.bookmarks != null) widget.bookmarks!,
    ]),
    builder: (BuildContext context, Widget? child) {
      final TopicsController controller = widget.controller;
      if (controller.loading) {
        return const Center(child: CircularProgressIndicator());
      }
      if (controller.error != null) {
        return _failure(
          controller.error!,
          () => controller.initialize(widget.context),
        );
      }
      if (controller.selectedTopicId != null) return _detail(controller);
      return _catalogue(controller);
    },
  );

  Widget _catalogue(TopicsController controller) {
    final String query = _search.text.toLowerCase().trim();
    final List<PublicTopicSummary> topics = (controller.catalogue?.topics ?? [])
        .where((PublicTopicSummary topic) {
          if (!_showHidden && controller.hidden.contains(topic.id)) {
            return false;
          }
          if (_onlyRelated && !controller.relatedIds.contains(topic.id)) {
            return false;
          }
          if (_onlyFollowed && !controller.followed.contains(topic.id)) {
            return false;
          }
          return query.isEmpty ||
              <String>[
                controller.nameOf(topic),
                topic.name,
                topic.id,
                ...topic.aliases,
              ].any((String name) => name.toLowerCase().contains(query));
        })
        .toList(growable: false);
    return CustomScrollView(
      key: const PageStorageKey<String>('public-topic-catalogue'),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                StudyOfflineStatus(
                  installed: controller.isInstalled,
                  onManageDownloads: widget.onManageDownloads,
                ),
                Text(
                  UiStrings.of(context).text('Public topics · {label}', {
                    'label': widget.context.label,
                  }),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _search,
                  decoration: InputDecoration(
                    labelText: UiStrings.of(context).text('Find a topic'),
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const SizedBox(height: 8),
                if (controller.availableLocales.isNotEmpty)
                  DropdownButtonFormField<String>(
                    key: ValueKey<String>(controller.locale),
                    initialValue: controller.locale,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: UiStrings.of(
                        context,
                      ).text('Topic name language'),
                    ),
                    items: controller.availableLocales
                        .map(
                          (
                            PublicTopicLocale locale,
                          ) => DropdownMenuItem<String>(
                            value: locale.code,
                            child: Text(
                              '${locale.name ?? locale.code} (${locale.code})',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        )
                        .toList(growable: false),
                    onChanged: (String? locale) {
                      if (locale != null) {
                        unawaited(controller.selectLocale(locale));
                      }
                    },
                  ),
                if (controller.loadingNames) const LinearProgressIndicator(),
                if (controller.restoringPreferences)
                  Text(
                    UiStrings.of(
                      context,
                    ).text('Restoring local topic choices…'),
                  ),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: <Widget>[
                    FilterChip(
                      label: Text(
                        UiStrings.of(context).text('Related ({length})', {
                          'length': controller.relatedIds.length,
                        }),
                      ),
                      selected: _onlyRelated,
                      onSelected: (bool value) =>
                          setState(() => _onlyRelated = value),
                    ),
                    FilterChip(
                      label: Text(UiStrings.of(context).text('Followed')),
                      selected: _onlyFollowed,
                      onSelected: (bool value) =>
                          setState(() => _onlyFollowed = value),
                    ),
                    FilterChip(
                      label: Text(UiStrings.of(context).text('Show hidden')),
                      selected: _showHidden,
                      onSelected: (bool value) =>
                          setState(() => _showHidden = value),
                    ),
                  ],
                ),
                if (controller.associationError != null)
                  Text('${controller.associationError}'),
                if (controller.localeError != null)
                  Text(
                    UiStrings.of(context).text(
                      'Using English names. {localeError}',
                      {'localeError': controller.localeError.toString()},
                    ),
                  ),
                if (controller.preferenceError != null)
                  Text(
                    UiStrings.of(context).text(
                      'Could not save or restore your topic choices. {preferenceError}',
                      {
                        'preferenceError': controller.preferenceError
                            .toString(),
                      },
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (topics.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  UiStrings.of(context).text(
                    'No topics match these choices. A verse with no public associations is valid.',
                  ),
                ),
              ),
            ),
          )
        else
          SliverList.builder(
            itemCount: topics.length,
            itemBuilder: (BuildContext context, int index) {
              final PublicTopicSummary topic = topics[index];
              return Card(
                margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    ListTile(
                      leading: Semantics(
                        label: UiStrings.of(
                          context,
                        ).text('Topic color {color}', {'color': topic.color}),
                        child: CircleAvatar(
                          radius: 12,
                          backgroundColor: _color(topic.color),
                        ),
                      ),
                      title: Text(controller.nameOf(topic)),
                      subtitle: Text(
                        UiStrings.of(
                          context,
                        ).text('{verseCount} verse associations{here}', {
                          'verseCount': topic.verseCount,
                          'here': controller.relatedIds.contains(topic.id)
                              ? ' · Related here'
                              : '',
                        }),
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () => unawaited(controller.selectTopic(topic.id)),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Wrap(
                        spacing: 8,
                        children: <Widget>[
                          TextButton.icon(
                            onPressed:
                                controller.restoringPreferences ||
                                    controller.savingPreferences.contains(
                                      topic.id,
                                    )
                                ? null
                                : () => unawaited(
                                    controller.setFollowed(
                                      topic.id,
                                      !controller.followed.contains(topic.id),
                                    ),
                                  ),
                            icon: Icon(
                              controller.followed.contains(topic.id)
                                  ? Icons.star
                                  : Icons.star_border,
                            ),
                            label: Text(
                              controller.followed.contains(topic.id)
                                  ? UiStrings.of(context).text('Unfollow')
                                  : UiStrings.of(context).text('Follow'),
                            ),
                          ),
                          TextButton.icon(
                            onPressed:
                                controller.restoringPreferences ||
                                    controller.savingPreferences.contains(
                                      topic.id,
                                    )
                                ? null
                                : () => unawaited(
                                    controller.setHidden(
                                      topic.id,
                                      !controller.hidden.contains(topic.id),
                                    ),
                                  ),
                            icon: Icon(
                              controller.hidden.contains(topic.id)
                                  ? Icons.visibility
                                  : Icons.visibility_off,
                            ),
                            label: Text(
                              controller.hidden.contains(topic.id)
                                  ? UiStrings.of(context).text('Show topic')
                                  : UiStrings.of(context).text('Hide topic'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
      ],
    );
  }

  Widget _detail(TopicsController controller) {
    final PublicTopic? topic = controller.selectedTopic;
    final List<ReferenceSelection> selections = topic?.selections ?? [];
    return CustomScrollView(
      key: PageStorageKey<String>('public-topic:${controller.selectedTopicId}'),
      slivers: <Widget>[
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: StudyOfflineStatus(
              installed: controller.isInstalled,
              onManageDownloads: widget.onManageDownloads,
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                TextButton.icon(
                  onPressed: controller.closeTopic,
                  icon: const Icon(Icons.arrow_back),
                  label: Text(UiStrings.of(context).text('All topics')),
                ),
                if (topic != null && widget.bookmarks != null) ...[
                  FilledButton.tonalIcon(
                    onPressed: widget.bookmarks!.busy
                        ? null
                        : () => unawaited(
                            widget.bookmarks!.download(
                              topicId: topic.id,
                              translation: widget.context.translation,
                              locale: controller.locale,
                            ),
                          ),
                    icon: const Icon(Icons.download),
                    label: Text(
                      UiStrings.of(context).text('Download global bookmarks'),
                    ),
                  ),
                  if (widget.onOpenBookmarks != null)
                    TextButton.icon(
                      onPressed: () => widget.onOpenBookmarks!(topic.id),
                      icon: const Icon(Icons.bookmarks_outlined),
                      label: Text(
                        UiStrings.of(context).text('Open saved topic'),
                      ),
                    ),
                  if (widget.bookmarks!.error != null)
                    Text(widget.bookmarks!.error.toString()),
                ],
                if (topic != null)
                  FilledButton.tonalIcon(
                    onPressed: controller.copying
                        ? null
                        : () => unawaited(_copyTopic()),
                    icon: const Icon(Icons.copy_all),
                    label: Text(
                      controller.copying
                          ? UiStrings.of(context).text('Copying…')
                          : UiStrings.of(context).text('Copy to my markings'),
                    ),
                  ),
              ],
            ),
          ),
        ),
        if (controller.loadingTopic)
          const SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: CircularProgressIndicator()),
          )
        else if (controller.topicError != null)
          SliverFillRemaining(
            hasScrollBody: false,
            child: _failure(
              controller.topicError!,
              () => controller.selectTopic(controller.selectedTopicId!),
            ),
          )
        else if (topic != null) ...<Widget>[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  SelectableText(
                    topic.localizedName(controller.locale),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  Text(
                    UiStrings.of(context).text(
                      '{length} canonical verse associations · Public getBible Bookmarks v1',
                      {'length': topic.coordinates.length},
                    ),
                  ),
                  Text(
                    UiStrings.of(context).text(
                      'Verses use your selected Bible. Missing verses are shown as unavailable.',
                    ),
                  ),
                  if (controller.copyResult != null)
                    Text(
                      UiStrings.of(context).text(
                        '{added} new markings copied. Your private group is independent of public updates.',
                        {'added': controller.copyResult!.added},
                      ),
                    ),
                  if (controller.copyError != null)
                    Text(
                      UiStrings.of(context).text(
                        'Copy failed; retry is safe. {copyError}',
                        {'copyError': controller.copyError.toString()},
                      ),
                    ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
          if (selections.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  UiStrings.of(
                    context,
                  ).text('This topic has no verse associations.'),
                ),
              ),
            )
          else if (widget.referenceLookup != null)
            TopicVerseList(
              key: ValueKey('public-topic:${topic.id}'),
              lookup: widget.referenceLookup!,
              preferences: widget.preferences,
              items: [
                for (final coordinate in topic.coordinates)
                  TopicVerseItem(
                    passage: Passage(
                      translation: widget.context.translation,
                      book: coordinate.book,
                      chapter: coordinate.chapter,
                      verse: coordinate.verse,
                    ),
                    reference:
                        '${UiStrings.of(context).text('Book {book}', {'book': coordinate.book})} ${coordinate.chapter}:${coordinate.verse}',
                    global: true,
                  ),
              ],
              onOpen: (item) => unawaited(
                widget.onPreviewReference(
                  StructuredReferenceRequest(
                    translation: widget.context.translation,
                    translationName: widget.context.translationName,
                    translationDirection: widget.context.direction,
                    sourceLabel: topic.localizedName(controller.locale),
                    selections: [ReferenceSelection.verse(item.passage)],
                  ),
                ),
              ),
            )
          else
            SliverList.builder(
              itemCount: selections.length,
              itemBuilder: (BuildContext context, int index) {
                final ReferenceSelection selection = selections[index];
                final String bookName = selection.book == widget.context.book
                    ? widget.context.bookName
                    : UiStrings.of(
                        context,
                      ).text('Book {book}', {'book': selection.book});
                return ListTile(
                  title: Text('$bookName ${selection.chapter}'),
                  subtitle: Text(
                    UiStrings.of(context).text('Verses {verses}', {
                      'verses': _verseLabel(selection.verses),
                    }),
                  ),
                  trailing: const Icon(Icons.menu_book),
                  onTap: () => unawaited(
                    widget.onPreviewReference(
                      StructuredReferenceRequest(
                        translation: widget.context.translation,
                        translationName: widget.context.translationName,
                        translationDirection: widget.context.direction,
                        sourceLabel:
                            '${topic.localizedName(controller.locale)} · $bookName ${selection.chapter}',
                        selections: <ReferenceSelection>[selection],
                      ),
                    ),
                  ),
                );
              },
            ),
        ],
      ],
    );
  }

  Widget _failure(Object error, Future<void> Function() retry) => Center(
    child: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('$error'),
          StudyOfflineStatus(
            installed: null,
            onManageDownloads: widget.onManageDownloads,
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: () => unawaited(retry()),
            icon: const Icon(Icons.refresh),
            label: Text(UiStrings.of(context).text('Retry')),
          ),
        ],
      ),
    ),
  );

  Future<void> _copyTopic() async {
    final TopicsController controller = widget.controller;
    try {
      final PublicTopicCopyPreview preview = await controller.previewCopy();
      if (!mounted) return;
      final bool confirmed =
          await showDialog<bool>(
            context: context,
            builder: (BuildContext context) => AlertDialog(
              title: Text(
                UiStrings.of(context).text('Copy public topic to my markings?'),
              ),
              content: SingleChildScrollView(
                child: Text(
                  UiStrings.of(context).text(
                    '{groupName}\n\n{newAssociationCount} new whole-verse markings; {alreadyPresent} already present.\n\nThis creates or adds to your independent private copy. Existing groups, notes and markings stay intact. Only canonical coordinates and the public topic color are copied; Scripture text is not downloaded. Public changes will not edit or delete your copy.',
                    {
                      'groupName': preview.groupName,
                      'newAssociationCount': preview.newAssociationCount,
                      'alreadyPresent': preview.alreadyPresent,
                    },
                  ),
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(UiStrings.of(context).text('Cancel')),
                ),
                FilledButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(UiStrings.of(context).text('Copy markings')),
                ),
              ],
            ),
          ) ??
          false;
      if (!mounted || !confirmed) return;
      if (await controller.copy(preview)) {
        await widget.onPrivateCopyCommitted?.call();
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              UiStrings.of(
                context,
              ).text('Could not prepare the copy. {error}', {'error': error}),
            ),
          ),
        );
      }
    }
  }
}

Color _color(String value) =>
    Color(int.parse(value.substring(1), radix: 16) | 0xff000000);

String _verseLabel(List<int> verses) {
  final List<String> ranges = <String>[];
  for (int start = 0; start < verses.length;) {
    int end = start;
    while (end + 1 < verses.length && verses[end + 1] == verses[end] + 1) {
      end++;
    }
    ranges.add(
      start == end ? '${verses[start]}' : '${verses[start]}–${verses[end]}',
    );
    start = end + 1;
  }
  return ranges.join(', ');
}
