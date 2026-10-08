import '../../core/json.dart';
import 'passage.dart';
import 'reference.dart';

const int maxNotebookTitleRunes = 200;
const int maxNotebookBlockCodeUnits = 100000;
const int maxNotebookDocumentCodeUnits = 1000000;
const int maxNotebookBlocks = 1000;

/// Private Scripture attribution captured when the user inserts a quotation.
/// It never tracks a later public source refresh or silently changes translation.
final class NotebookReference {
  NotebookReference({
    required this.passage,
    required this.label,
    this.quotation = '',
    this.direction = 'LTR',
  }) {
    passage.validated();
    if (passage.chapter < 1 ||
        passage.verse == null ||
        label.trim().isEmpty ||
        label.length > 1000 ||
        quotation.length > maxNotebookBlockCodeUnits ||
        (direction != 'LTR' && direction != 'RTL')) {
      throw const FormatException(
        'A notebook reference requires a valid Scripture verse and label.',
      );
    }
  }

  factory NotebookReference.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'notebook reference');
    return NotebookReference(
      passage: Passage.fromJson(json['passage']),
      label: requireString(json, 'label'),
      quotation: optionalString(json, 'quotation'),
      direction: optionalString(json, 'direction', 'LTR'),
    );
  }

  final Passage passage;
  final String label;
  final String quotation;
  final String direction;
  StructuredReferenceRequest get previewRequest => StructuredReferenceRequest(
    translation: passage.translation,
    sourceLabel: label,
    translationDirection: direction,
    selections: <ReferenceSelection>[ReferenceSelection.verse(passage)],
  );
  JsonMap toJson() => <String, Object?>{
    'passage': passage.toJson(),
    'label': label,
    'quotation': quotation,
    'direction': direction,
  };
}

/// Block identity is stable across edits and moves. Rank is derived from its
/// position in the notebook's immutable ordered block list when persisted.
final class NotebookBlock {
  NotebookBlock({
    required this.id,
    required this.text,
    required this.createdAt,
    required this.updatedAt,
    this.reference,
  }) {
    _validateId(id);
    _validateTimes(createdAt, updatedAt);
    if (text.length > maxNotebookBlockCodeUnits) {
      throw const FormatException(
        'A notebook block is limited to 100,000 characters.',
      );
    }
  }

  factory NotebookBlock.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'notebook block');
    return NotebookBlock(
      id: requireString(json, 'id'),
      text: requireString(json, 'text'),
      createdAt: _time(json, 'createdAt'),
      updatedAt: _time(json, 'updatedAt'),
      reference: json['reference'] == null
          ? null
          : NotebookReference.fromJson(json['reference']),
    );
  }

  final String id;
  final String text;
  final DateTime createdAt;
  final DateTime updatedAt;
  final NotebookReference? reference;
  NotebookBlock withText(String value, DateTime now) => NotebookBlock(
    id: id,
    text: value,
    createdAt: createdAt,
    updatedAt: now,
    reference: reference,
  );
  JsonMap toJson() => <String, Object?>{
    'id': id,
    'text': text,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    if (reference != null) 'reference': reference!.toJson(),
  };
}

/// A versioned private document, independent from canonical inline verse notes.
final class Notebook {
  Notebook({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
    required Iterable<NotebookBlock> blocks,
  }) : blocks = List<NotebookBlock>.unmodifiable(blocks) {
    _validateId(id);
    _validateTimes(createdAt, updatedAt);
    if (title.runes.length > maxNotebookTitleRunes ||
        revision < 1 ||
        this.blocks.length > maxNotebookBlocks ||
        this.blocks.map((NotebookBlock block) => block.id).toSet().length !=
            this.blocks.length ||
        textCodeUnits > maxNotebookDocumentCodeUnits) {
      throw const FormatException(
        'The notebook exceeds its document limits or contains duplicate block identities.',
      );
    }
  }

  factory Notebook.fromJson(Object? value) {
    final JsonMap json = requireJsonMap(value, 'notebook');
    if (requireInt(json, 'version') != 1) {
      throw const FormatException('This notebook format is unsupported.');
    }
    return Notebook(
      id: requireString(json, 'id'),
      title: requireString(json, 'title'),
      createdAt: _time(json, 'createdAt'),
      updatedAt: _time(json, 'updatedAt'),
      revision: requireInt(json, 'revision'),
      blocks: requireJsonList(
        json['blocks'],
        'notebook blocks',
      ).map(NotebookBlock.fromJson),
    );
  }

  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int revision;
  final List<NotebookBlock> blocks;
  int get textCodeUnits => blocks.fold<int>(
    title.length,
    (int total, NotebookBlock block) =>
        total + block.text.length + (block.reference?.quotation.length ?? 0),
  );
  int get titleTextCapacity =>
      maxNotebookDocumentCodeUnits - textCodeUnits + title.length;
  int blockTextCapacity(String id) {
    final NotebookBlock block = blocks.firstWhere(
      (NotebookBlock block) => block.id == id,
    );
    final int documentCapacity =
        maxNotebookDocumentCodeUnits - textCodeUnits + block.text.length;
    return documentCapacity < maxNotebookBlockCodeUnits
        ? documentCapacity
        : maxNotebookBlockCodeUnits;
  }

  String get displayTitle => title.trim().isEmpty ? 'Untitled notebook' : title;
  Notebook edit({
    String? title,
    Iterable<NotebookBlock>? blocks,
    required DateTime now,
  }) => Notebook(
    id: id,
    title: title ?? this.title,
    createdAt: createdAt,
    updatedAt: now,
    revision: revision + 1,
    blocks: blocks ?? this.blocks,
  );
  JsonMap toJson() => <String, Object?>{
    'version': 1,
    'id': id,
    'title': title,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'updatedAt': updatedAt.millisecondsSinceEpoch,
    'revision': revision,
    'blocks': blocks
        .map((NotebookBlock block) => block.toJson())
        .toList(growable: false),
  };
}

/// Notebook lists load metadata only. Large private document bodies are loaded
/// on selection, rather than retaining every sermon in the presentation state.
final class NotebookSummary {
  const NotebookSummary({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    required this.revision,
    required this.blockCount,
  });
  factory NotebookSummary.of(Notebook notebook) => NotebookSummary(
    id: notebook.id,
    title: notebook.title,
    createdAt: notebook.createdAt,
    updatedAt: notebook.updatedAt,
    revision: notebook.revision,
    blockCount: notebook.blocks.length,
  );
  final String id;
  final String title;
  final DateTime createdAt;
  final DateTime updatedAt;
  final int revision;
  final int blockCount;
  String get displayTitle => title.trim().isEmpty ? 'Untitled notebook' : title;
}

/// The base revision survives restart so a recovered draft cannot silently
/// overwrite edits made by another local editor after the draft was created.
final class NotebookDraft {
  const NotebookDraft({
    required this.notebook,
    required this.baseRevision,
    this.editorId = 'primary',
  });
  final Notebook notebook;
  final int? baseRevision;
  final String editorId;
}

final class NotebookConflictException implements Exception {
  const NotebookConflictException();
  @override
  String toString() =>
      'This notebook changed in another editor. Your draft is retained; save it as a new notebook.';
}

void _validateId(String id) {
  if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(id)) {
    throw const FormatException('A notebook identity is invalid.');
  }
}

void _validateTimes(DateTime created, DateTime updated) {
  if (created.millisecondsSinceEpoch < 0 || updated.isBefore(created)) {
    throw const FormatException('A notebook timestamp is invalid.');
  }
}

DateTime _time(JsonMap json, String key) =>
    DateTime.fromMillisecondsSinceEpoch(requireInt(json, key), isUtc: true);
