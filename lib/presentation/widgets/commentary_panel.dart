import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/commentary_controller.dart';
import '../../core/ui_strings.dart';
import '../../domain/models/commentary.dart';
import '../../domain/models/reference.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/models/study_citation.dart';
import '../../domain/models/study_context.dart';
import 'study_offline_status.dart';

/// Plain native study text. The injected preview action reuses the reader's
/// selected-Bible Query surface; this widget owns no network or storage access.
final class CommentaryPanel extends StatefulWidget {
  const CommentaryPanel({
    required this.controller,
    required this.context,
    required this.onPreviewReference,
    this.onSetUpOffline,
    super.key,
  });

  final CommentaryController controller;
  final StudyContext context;
  final Future<void> Function(ReferenceRequest) onPreviewReference;
  final VoidCallback? onSetUpOffline;

  @override
  State<CommentaryPanel> createState() => _CommentaryPanelState();
}

final class _CommentaryPanelState extends State<CommentaryPanel> {
  int _openingGeneration = 0;

  @override
  void initState() {
    super.initState();
    _openAfterBuild();
  }

  @override
  void didUpdateWidget(CommentaryPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller ||
        oldWidget.context != widget.context) {
      oldWidget.controller.close(notify: false);
      _openAfterBuild();
    }
  }

  void _openAfterBuild() {
    final int generation = ++_openingGeneration;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && generation == _openingGeneration) {
        unawaited(widget.controller.open(widget.context));
      }
    });
  }

  @override
  void dispose() {
    _openingGeneration++;
    widget.controller.close(notify: false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (BuildContext context, Widget? child) {
      final CommentaryController controller = widget.controller;
      final CommentaryMetadata? metadata = controller.metadata;
      return SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            StudyOfflineStatus(
              installed: controller.selectedModule == null
                  ? null
                  : controller.isInstalled,
              onSetUpOffline: widget.onSetUpOffline,
            ),
            Text(
              widget.context.label,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            if (controller.modules.isNotEmpty)
              DropdownButtonFormField<String>(
                key: ValueKey<String>(
                  'commentary-module-${controller.selectedModule?.id ?? 'none'}',
                ),
                initialValue: controller.selectedModule?.id,
                isExpanded: true,
                itemHeight: null,
                decoration: InputDecoration(
                  labelText: UiStrings.of(context).text('Commentary resource'),
                  border: OutlineInputBorder(),
                ),
                hint: Text(UiStrings.of(context).text('Choose a commentary')),
                items: controller.modules
                    .map(
                      (CommentaryModule module) => DropdownMenuItem<String>(
                        value: module.id,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(
                            '${module.name} · ${module.language}',
                            maxLines: 3,
                          ),
                        ),
                      ),
                    )
                    .toList(),
                onChanged: (String? id) {
                  if (id != null) unawaited(controller.selectModule(id));
                },
              ),
            if (controller.canSelectVerse) ...<Widget>[
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  ChoiceChip(
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    label: Text(
                      UiStrings.of(context).text('Verse {verse}', {
                        'verse': widget.context.verseNumber!,
                      }),
                    ),
                    selected: controller.verseMode,
                    onSelected: (_) => controller.setVerseMode(true),
                  ),
                  ChoiceChip(
                    materialTapTargetSize: MaterialTapTargetSize.padded,
                    label: Text(UiStrings.of(context).text('Whole chapter')),
                    selected: !controller.verseMode,
                    onSelected: (_) => controller.setVerseMode(false),
                  ),
                ],
              ),
            ],
            if (controller.selectedModule != null &&
                !controller.isCompatible(
                  controller.selectedModule!,
                )) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                UiStrings.of(context).text(
                  'This resource is in {sourceLanguage}; your Bible is in {bibleLanguage}.',
                  {
                    'sourceLanguage': controller.selectedModule!.language,
                    'bibleLanguage': widget.context.language,
                  },
                ),
              ),
            ],
            if (controller.preferenceWarning != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(UiStrings.of(context).text(controller.preferenceWarning!)),
            ],
            const SizedBox(height: 16),
            if (controller.introduction != null)
              _Introduction(
                title: UiStrings.of(context).text('Book introduction'),
                entries: controller.introduction!.entries,
                studyContext: widget.context,
                language: metadata?.language ?? widget.context.language,
                onPreviewReference: widget.onPreviewReference,
              ),
            if (controller.chapter?.entries.any((entry) => entry.verse == 0) ??
                false)
              _Introduction(
                title: UiStrings.of(context).text('Chapter introduction'),
                entries: controller.chapter!.entries
                    .where((entry) => entry.verse == 0)
                    .toList(),
                studyContext: widget.context,
                language: metadata?.language ?? widget.context.language,
                onPreviewReference: widget.onPreviewReference,
              ),
            if (controller.introductionError != null)
              _Status(
                message: UiStrings.of(context).text(
                  'The book introduction could not be loaded. Chapter commentary remains available.',
                ),
                onRetry: controller.retry,
              ),
            if (controller.isLoading)
              Semantics(
                label: UiStrings.of(context).text('Loading commentary'),
                liveRegion: true,
                child: const LinearProgressIndicator(),
              )
            else if (controller.error != null)
              _Status(
                message: controller.error.toString(),
                onRetry: controller.retry,
              )
            else if (controller.availability ==
                CommentaryAvailability.selectResource)
              Text(
                UiStrings.of(context).text(
                  'No commentary in this Bible’s language is selected. Choose an available resource explicitly; its source language will be shown.',
                ),
              )
            else if (controller.availability ==
                CommentaryAvailability.unavailableChapter)
              _Status(
                message: UiStrings.of(context).text(
                  'This resource has no published commentary for {reference}.',
                  {'reference': widget.context.label},
                ),
                onRetry: controller.retry,
              )
            else if (controller.availability ==
                CommentaryAvailability.unavailableVerse)
              Text(
                controller.verseMode
                    ? UiStrings.of(context).text(
                        'This chapter has no commentary covering verse {verse}. Try Whole chapter to read its other material.',
                        {'verse': widget.context.verseNumber!},
                      )
                    : UiStrings.of(context).text(
                        'This published chapter contains no commentary entries.',
                      ),
              )
            else
              for (final CommentaryQuotation quotation
                  in CommentaryQuotation.group(
                    controller.entries.where((entry) => !entry.isIntroduction),
                  ))
                _Quotation(
                  quotation: quotation,
                  studyContext: widget.context,
                  language: metadata?.language ?? widget.context.language,
                  onPreviewReference: widget.onPreviewReference,
                ),
            if (metadata != null) ...<Widget>[
              const Divider(height: 32),
              Text(
                UiStrings.of(context).text('Source: {name} · {language}', {
                  'name': metadata.name,
                  'language': metadata.language,
                }),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              SelectableText(
                '${metadata.sourceName}\n${metadata.sourceModuleUrl}\n${metadata.license}${metadata.copyright.isEmpty ? '' : '\n${metadata.copyright}'}',
              ),
              const SizedBox(height: 8),
              Text(
                UiStrings.of(context).text(
                  'Citations were resolved by {api} ({versification}). Preview requests use {bible}; availability and versification may differ.',
                  {
                    'api': metadata.references.api,
                    'versification': metadata.references.versification,
                    'bible':
                        widget.context.translationName ??
                        widget.context.translation.toUpperCase(),
                  },
                ),
              ),
              if (metadata.about.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: SelectableText(metadata.about),
                ),
            ],
          ],
        ),
      );
    },
  );
}

final class _Status extends StatelessWidget {
  const _Status({required this.message, required this.onRetry});
  final String message;
  final Future<void> Function() onRetry;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Semantics(liveRegion: true, child: Text(message)),
      const SizedBox(height: 8),
      OutlinedButton.icon(
        onPressed: () => unawaited(onRetry()),
        icon: const Icon(Icons.refresh),
        label: Text(UiStrings.of(context).text('Retry')),
      ),
    ],
  );
}

final class _Quotation extends StatelessWidget {
  const _Quotation({
    required this.quotation,
    required this.studyContext,
    required this.language,
    required this.onPreviewReference,
  });
  final CommentaryQuotation quotation;
  final StudyContext studyContext;
  final String language;
  final Future<void> Function(ReferenceRequest) onPreviewReference;

  @override
  Widget build(BuildContext context) {
    final List<StudyCitation> citations = <StudyCitation>[];
    final Set<String> seen = <String>{};
    for (final CommentaryEntry entry in quotation.entries) {
      for (final StudyCitation citation in entry.references) {
        final String key =
            '${citation.reference}|${citation.osis}|${citation.book}|${citation.chapter}|${citation.verse}|${citation.verses.join(',')}';
        if (seen.add(key)) citations.add(citation);
      }
    }
    final bool rtl = <String>{
      'ar',
      'he',
      'fa',
      'ur',
    }.contains(language.toLowerCase().split('-').first);
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          for (final CommentaryEntry entry in quotation.entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                '${_coverage(context, entry)}${entry.osis == null ? '' : ' · ${entry.osis}'}',
                style: Theme.of(context).textTheme.labelLarge,
              ),
            ),
          const SizedBox(height: 4),
          SelectableText(
            quotation.text,
            textDirection: rtl ? TextDirection.rtl : TextDirection.ltr,
          ),
          if (citations.isNotEmpty) ...<Widget>[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: citations
                  .map(
                    (StudyCitation citation) => OutlinedButton(
                      onPressed: citation.isScripture
                          ? () => unawaited(
                              onPreviewReference(
                                citation.requestFor(studyContext),
                              ),
                            )
                          : null,
                      child: Text(citation.text ?? citation.reference),
                    ),
                  )
                  .toList(),
            ),
            if (citations.any(
              (StudyCitation citation) => !citation.isScripture,
            ))
              Text(
                UiStrings.of(context).text(
                  'An introduction citation has no Scripture verse to preview.',
                ),
              ),
          ],
        ],
      ),
    );
  }
}

/// Introductions keep their source chapter/verse-zero identity and never become
/// fabricated Scripture coordinates. Each section can be expanded by keyboard.
final class _Introduction extends StatelessWidget {
  const _Introduction({
    required this.title,
    required this.entries,
    required this.studyContext,
    required this.language,
    required this.onPreviewReference,
  });
  final String title;
  final List<CommentaryEntry> entries;
  final StudyContext studyContext;
  final String language;
  final Future<void> Function(ReferenceRequest) onPreviewReference;
  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: Text(title),
    children: [
      for (final quotation in CommentaryQuotation.group(entries))
        _Quotation(
          quotation: quotation,
          studyContext: studyContext,
          language: language,
          onPreviewReference: onPreviewReference,
        ),
    ],
  );
}

String _coverage(BuildContext context, CommentaryEntry entry) {
  final ui = UiStrings.of(context);
  if (entry.chapter == 0) return ui.text('Book introduction');
  if (entry.verse == 0) return ui.text('Chapter introduction');
  final verses = entry.verses.isEmpty ? [entry.verse] : entry.verses;
  return verses.length == 1
      ? ui.text('Chapter {chapter} · verse {verses}', {
          'chapter': entry.chapter,
          'verses': verses.join(', '),
        })
      : ui.text('Chapter {chapter} · verses {verses}', {
          'chapter': entry.chapter,
          'verses': verses.join(', '),
        });
}
