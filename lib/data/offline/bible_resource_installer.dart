import 'dart:convert';

import '../../core/json.dart';
import '../../core/request_cancellation.dart';
import '../../domain/models/bible.dart';
import '../../domain/models/offline_resource.dart';
import '../../domain/repositories/offline_resource_repository.dart';
import '../api/api_configuration.dart';
import '../api/api_transport.dart';
import 'bible_index_worker.dart';

/// A complete Bible uses its published bulk file once, not thousands of verse
/// requests. Activation follows exact-byte SHA and before/after revision checks.
final class BibleResourceInstaller implements OfflineResourceInstaller {
  BibleResourceInstaller(this.transport);
  final ApiTransport transport;
  Uri get sourceUri =>
      transport.configuration.endpoint(ApiService.bible).baseUri;
  @override
  Set<OfflineResourceKind> get supportedKinds => {OfflineResourceKind.bible};

  @override
  Future<List<OfflineResourceDescriptor>> discover(
    RequestCancellation cancellation,
  ) async {
    final response = await transport.get(
      ApiService.bible,
      'translations.json',
      cancellation: cancellation,
      forceRefresh: true,
    );
    final json = requireJsonMap(jsonDecode(response.text), 'Bible catalogue');
    return json.values
        .map(Translation.fromJson)
        .map(
          (translation) => OfflineResourceDescriptor(
            kind: OfflineResourceKind.bible,
            id: translation.abbreviation,
            title:
                '${translation.translation} (${translation.resolvedLanguage})',
            sourceUri: sourceUri,
            revision: translation.sha,
            attribution: [
              translation.distributionLicense,
              translation.distributionAbout,
              translation.distributionSource,
            ].where((text) => text.isNotEmpty).join('\n'),
          ),
        )
        .toList()
      ..sort((a, b) => a.title.compareTo(b.title));
  }

  @override
  Future<void> install(
    OfflineResourceDescriptor resource,
    OfflineInstallSink sink,
    RequestCancellation cancellation,
  ) async {
    if (resource.kind != OfflineResourceKind.bible ||
        resource.sourceUri != sourceUri ||
        !RegExp(r'^[a-z0-9_-]+$').hasMatch(resource.id)) {
      throw const FormatException(
        'The selected Bible belongs to another source.',
      );
    }
    final before = await _sha(resource.id, cancellation);
    sink.progress(0, null, 'Downloading the complete Bible');
    final response = await transport.get(
      ApiService.bible,
      '${resource.id}.json',
      maxBytes: ApiResponseLimits.bulk,
      cancellation: cancellation,
      forceRefresh: true,
    );
    transport.discardResponse(response);
    if (response.cachePolicy.noStore) {
      throw const FormatException(
        'This Bible source does not permit local installation.',
      );
    }
    Translation? verifiedTranslation;
    try {
      await indexBibleInWorker(response.bytes, resource.id, before, (
        batch,
      ) async {
        cancellation.throwIfCancelled();
        if (batch['documents'] case final Map<Object?, Object?> documents) {
          if (documents['translation'] case final String metadata) {
            verifiedTranslation = Translation.fromJson(jsonDecode(metadata));
          }
          for (final entry in documents.entries) {
            await sink.writeDocument(
              entry.key as String,
              entry.value as String,
            );
          }
        }
        if (batch['verses'] case final List<Object?> verses) {
          await sink.writeSearchVerses(
            verses.map((value) {
              final row = Map<String, Object?>.from(value as Map);
              return OfflineSearchVerse(
                book: row['book']! as int,
                chapter: row['chapter']! as int,
                verse: row['verse']! as int,
                bookName: row['bookName']! as String,
                direction: row['direction']! as String,
                verseJson: row['verseJson']! as String,
                text: row['text']! as String,
                normalizedText: row['normalizedText']! as String,
              );
            }).toList(),
          );
        }
        if (batch['completed'] case final int completed) {
          sink.progress(
            completed,
            batch['total'] as int?,
            'Validating and indexing Scripture',
          );
        }
      }, cancellation);
      if (await _sha(resource.id, cancellation) != before) {
        throw const FormatException(
          'The Bible changed during installation. Its previous installed copy is unchanged; retry the download.',
        );
      }
      final metadata = verifiedTranslation;
      if (metadata == null) {
        throw const FormatException(
          'The installed Bible has no translation metadata.',
        );
      }
      await sink.setVerifiedDescriptor(
        OfflineResourceDescriptor(
          kind: resource.kind,
          id: resource.id,
          title: '${metadata.translation} (${metadata.resolvedLanguage})',
          sourceUri: resource.sourceUri,
          revision: before,
          estimatedBytes: response.bytes.length,
          attribution: [
            metadata.distributionLicense,
            metadata.distributionAbout,
            metadata.distributionSource,
          ].where((text) => text.isNotEmpty).join('\n'),
        ),
      );
    } catch (_) {
      transport.discardResponse(response);
      rethrow;
    }
  }

  Future<String> _sha(String id, RequestCancellation cancellation) async {
    final response = await transport.get(
      ApiService.bible,
      '$id.sha',
      accept: 'text/plain',
      maxBytes: 128,
      cancellation: cancellation,
      forceRefresh: true,
    );
    final hash = response.text.trim().toLowerCase();
    if (!RegExp(r'^[a-f0-9]{40}$').hasMatch(hash)) {
      transport.discardResponse(response);
      throw const FormatException(
        'The Bible source returned an invalid SHA-1.',
      );
    }
    return hash;
  }
}
