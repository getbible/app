import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/request_cancellation.dart';
import '../domain/models/commentary.dart';
import '../domain/models/service_envelopes.dart';
import '../domain/models/study_context.dart';
import '../domain/repositories/commentary_repository.dart';
import '../domain/repositories/study_preferences_repository.dart';

enum CommentaryAvailability {
  selectResource,
  unavailableChapter,
  unavailableVerse,
  available,
}

/// Request ownership is scoped to Study, independent of Scripture navigation.
/// A changed module/context cancels the old request and never displays its data.
final class CommentaryController extends ChangeNotifier {
  CommentaryController({required this.repository, required this.preferences});

  final CommentaryRepository repository;
  final StudyPreferencesRepository preferences;
  final RequestOwner _owner = RequestOwner();
  final Map<String, String> _rememberedChoices = <String, String>{};
  Future<void> _preferenceQueue = Future<void>.value();
  StudyContext? _context;
  CommentaryCatalogue? _catalogue;
  CommentaryModule? _selected;
  CommentaryMetadata? _metadata;
  CommentaryCoverage? _coverage;
  CommentaryChapter? _chapter;
  Object? _error;
  String? _preferenceWarning;
  bool _loading = false;
  bool _verseMode = true;
  bool _disposed = false;

  StudyContext? get context => _context;
  List<CommentaryModule> get modules => _catalogue?.modules ?? const [];
  CommentaryModule? get selectedModule => _selected;
  CommentaryMetadata? get metadata => _metadata;
  CommentaryCoverage? get coverage => _coverage;
  CommentaryChapter? get chapter => _chapter;
  Object? get error => _error;
  String? get preferenceWarning => _preferenceWarning;
  bool get isLoading => _loading;
  bool get verseMode => _verseMode;
  bool get canSelectVerse => (_context?.verseNumber ?? 0) > 0;

  List<CommentaryEntry> get entries =>
      _chapter?.entriesForVerse(
        _verseMode && canSelectVerse ? _context?.verseNumber : null,
      ) ??
      const [];

  CommentaryAvailability get availability {
    if (_selected == null) return CommentaryAvailability.selectResource;
    if (_coverage != null && _chapter == null) {
      return CommentaryAvailability.unavailableChapter;
    }
    if (_chapter != null && entries.isEmpty) {
      return CommentaryAvailability.unavailableVerse;
    }
    return CommentaryAvailability.available;
  }

  bool isCompatible(CommentaryModule module) =>
      _context != null &&
      _language(module.language) == _language(_context!.language);

  Future<void> open(StudyContext context) async {
    if (_disposed) return;
    final RequestCancellation token = _owner.begin();
    final String? previousLanguage = _context?.language;
    _context = context;
    _verseMode = (context.verseNumber ?? 0) > 0;
    _beginLoading();
    try {
      final CommentaryCatalogue catalogue = await repository.catalogue(
        cancellation: token,
      );
      if (!_owner.owns(token)) return;
      _catalogue = catalogue;
      String? saved = _rememberedChoices[context.language];
      if (saved == null) {
        try {
          saved = await preferences.commentary(context.language);
        } catch (_) {
          if (_owner.owns(token)) {
            _preferenceWarning =
                'The saved commentary choice could not be read.';
          }
        }
      }
      if (!_owner.owns(token)) return;
      final List<CommentaryModule> compatible = modules
          .where(isCompatible)
          .toList();
      final CommentaryModule? previous = _selected;
      _selected =
          previous != null &&
              previousLanguage == context.language &&
              modules.any((CommentaryModule module) => module.id == previous.id)
          ? previous
          : null;
      if (_selected == null) {
        for (final CommentaryModule module in compatible) {
          if (module.id == saved) _selected = module;
        }
        _selected ??= compatible.isEmpty ? null : compatible.first;
      }
      if (_selected != null) await _loadSelected(token);
    } catch (error) {
      if (_owner.owns(token)) _error = error;
    } finally {
      _finishLoading(token);
    }
  }

  Future<void> selectModule(String id) async {
    if (_disposed || _context == null) return;
    CommentaryModule? selected;
    for (final CommentaryModule module in modules) {
      if (module.id == id) selected = module;
    }
    if (selected == null) return;
    final RequestCancellation token = _owner.begin();
    _selected = selected;
    _beginLoading();
    if (isCompatible(selected)) {
      final String language = _context!.language;
      _rememberedChoices[language] = selected.id;
      _remember(language, selected.id);
    }
    try {
      await _loadSelected(token);
    } catch (error) {
      if (_owner.owns(token)) _error = error;
    } finally {
      _finishLoading(token);
    }
  }

  void setVerseMode(bool verseMode) {
    if (_disposed || (verseMode && !canSelectVerse)) return;
    _verseMode = verseMode;
    notifyListeners();
  }

  Future<void> retry() async {
    final StudyContext? context = _context;
    if (context == null) return;
    if (_selected == null) {
      await open(context);
    } else {
      await selectModule(_selected!.id);
    }
  }

  Future<void> _loadSelected(RequestCancellation token) async {
    final CommentaryModule module = _selected!;
    final StudyContext context = _context!;
    final List<Object> details = await Future.wait<Object>(<Future<Object>>[
      repository.metadata(module.id, cancellation: token),
      repository.coverage(module.id, cancellation: token),
    ]);
    if (!_owner.owns(token)) return;
    final CommentaryMetadata metadata = details[0] as CommentaryMetadata;
    final CommentaryCoverage coverage = details[1] as CommentaryCoverage;
    if (metadata.language != module.language ||
        coverage.language != module.language) {
      throw const ApiFormatException(
        'The commentary language changed during loading.',
      );
    }
    _metadata = metadata;
    _coverage = coverage;
    if (!coverage.covers(context.book, context.chapter)) return;
    try {
      final CommentaryChapter chapter = await repository.chapter(
        module.id,
        context.book,
        context.chapter,
        cancellation: token,
      );
      if (!_owner.owns(token)) return;
      if (chapter.language != module.language) {
        throw const ApiFormatException(
          'The commentary chapter has a different language.',
        );
      }
      _chapter = chapter;
    } on ResourceUnavailableException {
      // A publication/coverage race remains an unavailable source chapter.
      // Scripture and private drafts are unaffected; the explicit Retry stays.
      if (!_owner.owns(token)) return;
      _chapter = null;
    }
  }

  void _beginLoading() {
    _metadata = null;
    _coverage = null;
    _chapter = null;
    _error = null;
    _preferenceWarning = null;
    _loading = true;
    notifyListeners();
  }

  void _finishLoading(RequestCancellation token) {
    if (!_owner.owns(token)) return;
    _loading = false;
    notifyListeners();
  }

  void _remember(String language, String module) {
    // Ordered writes ensure an older async save cannot overwrite the latest
    // module choice. Failure is visible but cannot block reading commentary.
    _preferenceQueue = _preferenceQueue.then((_) async {
      try {
        await preferences.setCommentary(language, module);
      } catch (_) {
        if (_disposed ||
            _context?.language != language ||
            _selected?.id != module) {
          return;
        }
        _preferenceWarning =
            'The commentary choice was not saved. Select it again to retry.';
        notifyListeners();
      }
    });
  }

  void close() {
    if (_disposed) return;
    _owner.cancel();
    _loading = false;
    _context = null;
    _selected = null;
    _metadata = null;
    _coverage = null;
    _chapter = null;
    _error = null;
    _preferenceWarning = null;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _owner.cancel();
    super.dispose();
  }
}

String _language(String language) =>
    language.toLowerCase().replaceAll('_', '-').split('-').first;
