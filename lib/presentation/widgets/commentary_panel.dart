import 'dart:async';

import 'package:flutter/material.dart';

import '../../application/commentary_controller.dart';
import '../../domain/models/commentary.dart';
import '../../domain/models/reference.dart';
import '../../domain/models/service_envelopes.dart';
import '../../domain/models/study_citation.dart';
import '../../domain/models/study_context.dart';

/// Plain native study text. The injected preview action reuses the reader's
/// selected-Bible Query surface; this widget owns no network or storage access.
final class CommentaryPanel extends StatefulWidget {
  const CommentaryPanel({
    required this.controller,
    required this.context,
    required this.onPreviewReference,
    super.key,
  });

  final CommentaryController controller;
  final StudyContext context;
  final Future<void> Function(ReferenceRequest) onPreviewReference;

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
                decoration: const InputDecoration(
                  labelText: 'Commentary resource',
                  border: OutlineInputBorder(),
                ),
                hint: const Text('Choose a commentary'),
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
                    label: Text('Verse ${widget.context.verseNumber}'),
                    selected: controller.verseMode,
                    onSelected: (_) => controller.setVerseMode(true),
                  ),
                  ChoiceChip(
                    label: const Text('Whole chapter'),
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
                'This resource is in ${controller.selectedModule!.language}; your Bible is in ${widget.context.language}.',
              ),
            ],
            if (controller.preferenceWarning != null) ...<Widget>[
              const SizedBox(height: 12),
              Text(controller.preferenceWarning!),
            ],
            const SizedBox(height: 16),
            if (controller.isLoading)
              Semantics(
                label: 'Loading commentary',
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
              const Text(
                'No commentary in this Bible’s language is selected. Choose an available resource explicitly; its source language will be shown.',
              )
            else if (controller.availability ==
                CommentaryAvailability.unavailableChapter)
              _Status(
                message:
                    'This resource has no published commentary for ${widget.context.label}.',
                onRetry: controller.retry,
              )
            else if (controller.availability ==
                CommentaryAvailability.unavailableVerse)
              Text(
                controller.verseMode
                    ? 'This chapter has no commentary covering verse ${widget.context.verseNumber}. Try Whole chapter to read its other material.'
                    : 'This published chapter contains no commentary entries.',
              )
            else
              for (final CommentaryQuotation quotation
                  in CommentaryQuotation.group(controller.entries))
                _Quotation(
                  quotation: quotation,
                  studyContext: widget.context,
                  language: metadata?.language ?? widget.context.language,
                  onPreviewReference: widget.onPreviewReference,
                ),
            if (metadata != null) ...<Widget>[
              const Divider(height: 32),
              Text(
                'Source: ${metadata.name} · ${metadata.language}',
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const SizedBox(height: 8),
              SelectableText(
                '${metadata.sourceName}\n${metadata.sourceModuleUrl}\n${metadata.license}${metadata.copyright.isEmpty ? '' : '\n${metadata.copyright}'}',
              ),
              const SizedBox(height: 8),
              Text(
                'Citations were resolved by ${metadata.references.api} (${metadata.references.versification}). Preview requests use ${widget.context.translationName ?? widget.context.translation.toUpperCase()}; availability and versification may differ.',
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
        label: const Text('Retry'),
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
                '${entry.coverageLabel}${entry.osis == null ? '' : ' · ${entry.osis}'}',
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
              const Text(
                'An introduction citation has no Scripture verse to preview.',
              ),
          ],
        ],
      ),
    );
  }
}
