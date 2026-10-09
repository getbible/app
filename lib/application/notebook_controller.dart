import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../domain/models/notebook.dart';
import '../domain/repositories/notebook_repository.dart';

/// Owns private edits beyond a Study widget's lifetime. Autosave is serialized;
/// an older completion cannot clear a newer draft, and a failed save keeps the
/// entire document available for retry or navigation back to its notebook.
final class NotebookController extends ChangeNotifier {
  NotebookController(
    this.repository, {
    this.autosaveDelay = const Duration(milliseconds: 300),
    DateTime Function()? clock,
    String Function()? createId,
  }) : _clock = clock ?? (() => DateTime.now().toUtc()),
       _createId = createId ?? _newId,
       _editorId = _newId();
  final NotebookRepository repository;
  final Duration autosaveDelay;
  final DateTime Function() _clock;
  final String Function() _createId;
  final String _editorId;
  final Map<String, NotebookSummary> _summaries = <String, NotebookSummary>{};
  final Map<String, Notebook> _drafts = <String, Notebook>{};
  final Map<String, int> _journaledRevisions = <String, int>{};
  final Map<String, int?> _draftBases = <String, int?>{};
  final Map<String, String> _draftOwners = <String, String>{};
  final Map<String, NotebookDraft> _recoveredOrigins =
      <String, NotebookDraft>{};
  final List<NotebookDraft> _additionalDrafts = <NotebookDraft>[];
  final Set<String> _conflicts = <String>{};
  final Map<String, Object> _errors = <String, Object>{};
  Notebook? _loaded;
  String? _selectedId;
  Object? _loadError;
  String? _inputLimitMessage;
  bool _loading = false;
  bool _initialized = false;
  bool _disposed = false;
  int _selectionGeneration = 0;
  Timer? _autosave;
  Future<bool>? _saving;

  List<NotebookSummary> get notebooks {
    final Map<String, NotebookSummary> combined = <String, NotebookSummary>{
      ..._summaries,
      for (final Notebook draft in _drafts.values)
        draft.id: NotebookSummary.of(draft),
    };
    return combined.values.toList()
      ..sort((NotebookSummary a, NotebookSummary b) {
        final int updated = b.updatedAt.compareTo(a.updatedAt);
        if (updated != 0) return updated;
        final int created = b.createdAt.compareTo(a.createdAt);
        return created == 0 ? a.id.compareTo(b.id) : created;
      });
  }

  String? get selectedId => _selectedId;
  Notebook? get notebook =>
      _drafts[_selectedId] ?? (_loaded?.id == _selectedId ? _loaded : null);
  bool get isLoading => _loading;
  bool get isSaving => _saving != null;
  bool get isDirty => _drafts.containsKey(_selectedId);
  bool get hasUnsavedDrafts =>
      _drafts.isNotEmpty || _additionalDrafts.isNotEmpty;

  /// A failed activation may still have a durable recoverable journal. Closing
  /// must be refused only when a current private revision has no durable copy.
  bool get hasUndurableDrafts => _drafts.entries.any(
    (MapEntry<String, Notebook> entry) =>
        _journaledRevisions[entry.key] != entry.value.revision,
  );
  Object? get error => _errors[_selectedId] ?? _loadError;
  int get unsavedCount => _drafts.length + _additionalDrafts.length;
  List<NotebookDraft> get additionalRecoveredDrafts =>
      List<NotebookDraft>.unmodifiable(_additionalDrafts);
  bool get hasConflict => _conflicts.contains(_selectedId);
  String? get inputLimitMessage => _inputLimitMessage;

  void reportInputLimit(String message) {
    if (_disposed || _inputLimitMessage == message) return;
    _inputLimitMessage = message;
    _notify();
  }

  Future<void> load() async {
    if (_initialized || _loading || _disposed) return;
    _loading = true;
    _loadError = null;
    _notify();
    try {
      final List<NotebookSummary> summaries = await repository.notebooks();
      final List<NotebookDraft> drafts = await repository.drafts();
      final String? savedSelection = await repository.selectedNotebook();
      if (_disposed) return;
      for (final NotebookSummary summary in summaries) {
        _summaries[summary.id] = summary;
      }
      for (final NotebookDraft stored in drafts) {
        final Notebook draft = stored.notebook;
        if (_drafts.containsKey(draft.id)) {
          _additionalDrafts.add(stored);
          continue;
        }
        _drafts[draft.id] = draft;
        _journaledRevisions[draft.id] = draft.revision;
        // A recovered journal belongs to its original writer. Every new
        // controller forks its own journal; two tabs must never adopt a shared
        // crashed-writer identity and replace each other's private revisions.
        _draftOwners[draft.id] = _editorId;
        _recoveredOrigins[draft.id] = stored;
        _draftBases[draft.id] = stored.baseRevision;
        if (_summaries[draft.id]?.revision != stored.baseRevision) {
          _conflicts.add(draft.id);
          _errors[draft.id] =
              'This notebook changed after its draft was created. Save your retained draft as a new notebook.';
        }
      }
      _selectedId =
          notebooks.any(
            (NotebookSummary summary) => summary.id == savedSelection,
          )
          ? savedSelection
          : notebooks.firstOrNull?.id;
      if (_selectedId != null && !_drafts.containsKey(_selectedId)) {
        _loaded = await repository.notebook(_selectedId!);
      }
      _initialized = true;
      if (_drafts.isNotEmpty) _scheduleAutosave();
    } catch (error) {
      _loadError = error;
    } finally {
      _loading = false;
      _notify();
    }
  }

  Future<void> selectNotebook(String id) async {
    if (_disposed || id == _selectedId) return;
    if (!notebooks.any((NotebookSummary summary) => summary.id == id)) return;
    final int generation = ++_selectionGeneration;
    await flush();
    if (_disposed || generation != _selectionGeneration) return;
    _loading = true;
    _loadError = null;
    _notify();
    try {
      final Notebook? document = _drafts[id] ?? await repository.notebook(id);
      if (_disposed || generation != _selectionGeneration) return;
      if (document == null) {
        throw const FormatException('This notebook is no longer available.');
      }
      _selectedId = id;
      _loaded = document;
      await repository.selectNotebook(id);
    } catch (error) {
      if (generation == _selectionGeneration) _loadError = error;
    } finally {
      if (generation == _selectionGeneration) {
        _loading = false;
        _notify();
      }
    }
  }

  /// Refreshes imported documents without discarding an open editor or its
  /// independent recovery journals. A failed journal write blocks the refresh.
  Future<void> reloadAfterImport() async {
    if (_disposed) return;
    await flush();
    if (hasUndurableDrafts) {
      throw const StorageException(
        'Save or retry the open notebook before refreshing imported data.',
      );
    }
    if (!_initialized) {
      await load();
      if (_loadError != null) {
        throw StorageException(
          'Could not reload imported notebooks.',
          _loadError,
        );
      }
      return;
    }
    final int generation = ++_selectionGeneration;
    final List<NotebookSummary> summaries = await repository.notebooks();
    final List<NotebookDraft> journals = await repository.drafts();
    final String? selected = await repository.selectedNotebook();
    if (_disposed || generation != _selectionGeneration) return;
    _summaries
      ..clear()
      ..addEntries(
        summaries.map((NotebookSummary item) => MapEntry(item.id, item)),
      );
    for (final NotebookDraft journal in journals) {
      final String id = journal.notebook.id;
      final NotebookDraft? origin = _recoveredOrigins[id];
      final bool represented =
          (_draftOwners[id] == journal.editorId && _drafts.containsKey(id)) ||
          (origin?.editorId == journal.editorId &&
              origin?.notebook.revision == journal.notebook.revision) ||
          _additionalDrafts.any(
            (NotebookDraft item) =>
                item.notebook.id == id &&
                item.editorId == journal.editorId &&
                item.notebook.revision == journal.notebook.revision,
          );
      if (represented) continue;
      if (_drafts.containsKey(id)) {
        _additionalDrafts.add(journal);
        continue;
      }
      _drafts[id] = journal.notebook;
      _journaledRevisions[id] = journal.notebook.revision;
      _draftOwners[id] = _editorId;
      _recoveredOrigins[id] = journal;
      _draftBases[id] = journal.baseRevision;
      if (_summaries[id]?.revision != journal.baseRevision) {
        _conflicts.add(id);
        _errors[id] =
            'This notebook changed after its draft was created. Save your retained draft as a new notebook.';
      }
    }
    final String? target =
        selected != null &&
            notebooks.any((NotebookSummary item) => item.id == selected)
        ? selected
        : _selectedId ?? notebooks.firstOrNull?.id;
    final Notebook? loaded = target == null || _drafts.containsKey(target)
        ? null
        : await repository.notebook(target);
    if (_disposed || generation != _selectionGeneration) return;
    _selectedId = target;
    if (loaded != null) _loaded = loaded;
    _notify();
  }

  Future<void> createNotebook({String title = 'New notebook'}) async {
    await load();
    if (!_initialized || _disposed) return;
    await flush();
    final DateTime now = _now();
    final Notebook created = Notebook(
      id: _createId(),
      title: title,
      createdAt: now,
      updatedAt: now,
      revision: 1,
      blocks: <NotebookBlock>[
        NotebookBlock(
          id: _createId(),
          text: '',
          createdAt: now,
          updatedAt: now,
        ),
      ],
    );
    _selectedId = created.id;
    _drafts[created.id] = created;
    _draftBases[created.id] = null;
    _draftOwners[created.id] = _editorId;
    _loaded = created;
    _loadError = null;
    _notify();
    await flush();
    try {
      await repository.selectNotebook(created.id);
    } catch (error) {
      _loadError = error;
      _notify();
    }
  }

  void updateTitle(String title) {
    final Notebook? current = notebook;
    if (current != null && title != current.title) {
      _edit(current.edit(title: title, now: _editTime(current)));
    }
  }

  void updateBlockText(String id, String text) {
    final Notebook? current = notebook;
    if (current == null) return;
    final int index = current.blocks.indexWhere(
      (NotebookBlock block) => block.id == id,
    );
    if (index < 0 || current.blocks[index].text == text) return;
    final DateTime now = _editTime(current);
    final List<NotebookBlock> blocks = <NotebookBlock>[...current.blocks];
    blocks[index] = blocks[index].withText(text, now);
    _edit(current.edit(blocks: blocks, now: now));
  }

  void addTextBlock() => _addBlock();
  void addReference(NotebookReference reference) =>
      _addBlock(reference: reference);
  void _addBlock({NotebookReference? reference}) {
    final Notebook? current = notebook;
    if (current == null) return;
    final DateTime now = _editTime(current);
    _edit(
      current.edit(
        now: now,
        blocks: <NotebookBlock>[
          ...current.blocks,
          NotebookBlock(
            id: _createId(),
            text: '',
            createdAt: now,
            updatedAt: now,
            reference: reference,
          ),
        ],
      ),
    );
  }

  void moveBlock(String id, int delta) {
    final Notebook? current = notebook;
    if (current == null || delta.abs() != 1) return;
    final int index = current.blocks.indexWhere(
      (NotebookBlock block) => block.id == id,
    );
    if (index < 0 ||
        index + delta < 0 ||
        index + delta >= current.blocks.length) {
      return;
    }
    final List<NotebookBlock> blocks = <NotebookBlock>[...current.blocks];
    final NotebookBlock moved = blocks.removeAt(index);
    blocks.insert(index + delta, moved);
    _edit(current.edit(now: _editTime(current), blocks: blocks));
  }

  void deleteBlock(String id) {
    final Notebook? current = notebook;
    if (current == null ||
        !current.blocks.any((NotebookBlock block) => block.id == id)) {
      return;
    }
    _edit(
      current.edit(
        now: _editTime(current),
        blocks: current.blocks.where((NotebookBlock block) => block.id != id),
      ),
    );
  }

  void _edit(Notebook value) {
    if (_disposed) return;
    _drafts[value.id] = value;
    _draftBases.putIfAbsent(value.id, () => _summaries[value.id]?.revision);
    _draftOwners.putIfAbsent(value.id, () => _editorId);
    _inputLimitMessage = null;
    if (!_conflicts.contains(value.id)) _errors.remove(value.id);
    _loadError = null;
    _scheduleAutosave();
    _notify();
  }

  DateTime _editTime(Notebook current) {
    final DateTime now = _now();
    return now.isBefore(current.updatedAt) ? current.updatedAt : now;
  }

  void _scheduleAutosave() {
    _autosave?.cancel();
    _autosave = Timer(autosaveDelay, () {
      unawaited(flush());
    });
  }

  Future<bool> flush() async {
    if (_disposed) return !hasUnsavedDrafts;
    _autosave?.cancel();
    if (_saving != null) return _saving!;
    if (_drafts.isEmpty) return _additionalDrafts.isEmpty;
    final Completer<bool> completion = Completer<bool>();
    _saving = completion.future;
    _notify();
    final bool saved = await _saveDrafts();
    _saving = null;
    completion.complete(saved);
    _notify();
    return saved;
  }

  Future<bool> _saveDrafts() async {
    final Set<String> failed = <String>{};
    while (_drafts.keys.any((String id) => !failed.contains(id))) {
      final String id = _drafts.keys.firstWhere(
        (String id) => !failed.contains(id),
      );
      final Notebook snapshot = _drafts[id]!;
      try {
        await repository.saveDraft(
          snapshot,
          expectedRevision: _draftBases[id],
          editorId: _draftOwners[id]!,
        );
        _journaledRevisions[id] = snapshot.revision;
        if (_conflicts.contains(id)) {
          // A conflict prevents activation, never durable private editing.
          // Persist its fork and retain the explicit-copy recovery action.
          if (_drafts[id]?.revision == snapshot.revision) failed.add(id);
          continue;
        }
        await repository.save(
          snapshot,
          expectedRevision: _draftBases[id],
          editorId: _draftOwners[id]!,
        );
        _summaries[id] = NotebookSummary.of(snapshot);
        _draftBases[id] = snapshot.revision;
        await _retireRecoveredOrigin(id);
        if (_drafts[id]?.revision == snapshot.revision) {
          _drafts.remove(id);
          _journaledRevisions.remove(id);
          _draftBases.remove(id);
          _draftOwners.remove(id);
          if (_selectedId == id) _loaded = snapshot;
          _errors.remove(id);
        }
      } catch (error) {
        _errors[id] = error;
        if (_isConflict(error)) _conflicts.add(id);
        failed.add(id);
      }
    }
    return !hasUnsavedDrafts;
  }

  Future<void> retry() async {
    if (!_initialized) {
      await load();
      return;
    }
    _errors.removeWhere((String id, Object error) => !_conflicts.contains(id));
    _loadError = null;
    await flush();
  }

  /// Deletion is an explicit confirmed UI action. Wait for in-flight saves
  /// first, so an older completion cannot recreate a deleted document.
  Future<bool> deleteNotebook(String id) async {
    _autosave?.cancel();
    await flush();
    try {
      await repository.delete(id);
      _additionalDrafts.removeWhere(
        (NotebookDraft draft) => draft.notebook.id == id,
      );
      _drafts.remove(id);
      _journaledRevisions.remove(id);
      _draftBases.remove(id);
      _draftOwners.remove(id);
      _recoveredOrigins.remove(id);
      _conflicts.remove(id);
      _summaries.remove(id);
      _errors.remove(id);
      if (_selectedId == id) {
        _selectedId = null;
        _loaded = null;
        final String? next = notebooks.firstOrNull?.id;
        if (next != null) await selectNotebook(next);
      }
      _notify();
      return true;
    } catch (error) {
      _errors[id] = error;
      _notify();
      return false;
    }
  }

  /// Preserve both versions of an optimistic-concurrency conflict. The original
  /// notebook remains intact; block IDs are freshly allocated for the copy.
  Future<void> recoverDraftAsNewNotebook() async {
    final Notebook? retained = notebook;
    if (retained == null || !hasConflict) return;
    await recoverSavedDraft(
      NotebookDraft(
        notebook: retained,
        baseRevision: _draftBases[retained.id],
        editorId: _draftOwners[retained.id]!,
      ),
    );
  }

  Future<void> recoverSavedDraft(NotebookDraft stored) async {
    final Notebook retained = stored.notebook;
    final DateTime now = _now();
    final String recoveredId = _createId();
    final String title = 'Recovered: ${retained.displayTitle}';
    final Notebook recovered = Notebook(
      id: recoveredId,
      title: String.fromCharCodes(title.runes.take(200)),
      createdAt: now,
      updatedAt: now,
      revision: 1,
      blocks: retained.blocks.map(
        (NotebookBlock block) => NotebookBlock(
          id: _createId(),
          text: block.text,
          createdAt: now,
          updatedAt: now,
          reference: block.reference,
        ),
      ),
    );
    _drafts[recoveredId] = recovered;
    _draftBases[recoveredId] = null;
    _draftOwners[recoveredId] = _editorId;
    _selectedId = recoveredId;
    _loaded = recovered;
    _notify();
    await flush();
    if (_drafts.containsKey(recoveredId)) return;
    try {
      await repository.discardDraft(
        retained.id,
        retained.revision,
        editorId: stored.editorId,
      );
      if (_draftOwners[retained.id] == stored.editorId) {
        await _retireRecoveredOrigin(retained.id);
        _drafts.remove(retained.id);
        _journaledRevisions.remove(retained.id);
        _draftBases.remove(retained.id);
        _draftOwners.remove(retained.id);
        _conflicts.remove(retained.id);
        _errors.remove(retained.id);
      }
      _additionalDrafts.removeWhere(
        (NotebookDraft draft) =>
            draft.notebook.id == retained.id &&
            draft.editorId == stored.editorId &&
            draft.notebook.revision == retained.revision,
      );
      await repository.selectNotebook(recoveredId);
    } catch (error) {
      _loadError = error;
    }
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _retireRecoveredOrigin(String id) async {
    final NotebookDraft? original = _recoveredOrigins.remove(id);
    if (original == null) return;
    try {
      // Compare the exact captured revision. A still-running original editor
      // may already have advanced its journal; that newer revision survives.
      await repository.discardDraft(
        original.notebook.id,
        original.notebook.revision,
        editorId: original.editorId,
      );
    } catch (error) {
      // Activation is already durable. A cleanup failure must not mark that
      // successful revision as uncommitted or retry with its obsolete base.
      _additionalDrafts.add(original);
      _loadError = error;
    }
  }

  DateTime _now() => DateTime.fromMillisecondsSinceEpoch(
    _clock().millisecondsSinceEpoch,
    isUtc: true,
  );

  @override
  void dispose() {
    _autosave?.cancel();
    // The application awaits flush before closing its database. Disposal never
    // starts a write that could race a closed database after a failed save.
    _disposed = true;
    super.dispose();
  }
}

String _newId() {
  final Random random = Random.secure();
  return List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
}

bool _isConflict(Object error) =>
    error is NotebookConflictException ||
    (error is StorageException &&
        error.cause != null &&
        _isConflict(error.cause!));
