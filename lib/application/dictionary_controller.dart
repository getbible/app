import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/request_cancellation.dart';
import '../domain/models/dictionary.dart';
import '../domain/models/reference.dart';
import '../domain/models/service_envelopes.dart';
import '../domain/models/study_context.dart';
import '../domain/repositories/dictionary_repository.dart';
import '../domain/repositories/study_preferences_repository.dart';
import 'dictionary_lookup.dart';

/// One Study dictionary context owns catalogue, module and entry requests.
/// Navigation keeps a bounded set of loaded snapshots; links never recurse or
/// request entries that the selected module's published index does not contain.
final class DictionaryController extends ChangeNotifier {
  DictionaryController({
    required this.repository,
    required this.preferences,
    this.historyLimit = 8,
  }) {
    if (historyLimit < 1 || historyLimit > 32) {
      throw ArgumentError.value(historyLimit, 'historyLimit');
    }
  }
  final DictionaryRepository repository;
  final StudyPreferencesRepository preferences;
  final int historyLimit;
  final RequestOwner _owner = RequestOwner();
  Future<void> _preferenceTail = Future<void>.value();
  final List<DictionaryEntry> _history = <DictionaryEntry>[];
  StudyContext? _context;
  DictionaryLookup? _lookup;
  DictionaryCatalogue? _catalogue;
  DictionaryMetadata? _metadata;
  DictionaryIndex? _index;
  DictionaryModule? _selected;
  DictionaryEntry? _entry;
  List<DictionaryIndexEntry> _matches = const <DictionaryIndexEntry>[];
  String _query = '';
  Object? _error;
  Object? _preferenceError;
  bool _loading = false;
  String? _requestedEntry;

  StudyContext? get context => _context;
  DictionaryLookup? get lookup => _lookup;
  List<DictionaryModule> get modules =>
      _catalogue?.modules ?? const <DictionaryModule>[];
  DictionaryModule? get selectedModule => _selected;
  DictionaryMetadata? get metadata => _metadata;
  DictionaryEntry? get entry => _entry;
  List<DictionaryIndexEntry> get matches => _matches;
  String get query => _query;
  Object? get error => _error;
  Object? get preferenceError => _preferenceError;
  bool get isLoading => _loading;
  bool get needsResourceChoice =>
      !_loading && _error == null && _selected == null;
  bool get canGoBack => _history.isNotEmpty;
  int get historyLength => _history.length;

  Future<void> open(StudyContext context) async {
    final RequestCancellation request = _owner.begin();
    _context = context;
    _lookup = DictionaryLookupBuilder.fromContext(context);
    _catalogue = null;
    _selected = null;
    _metadata = null;
    _index = null;
    _entry = null;
    _matches = const <DictionaryIndexEntry>[];
    _requestedEntry = null;
    _history.clear();
    _query = _lookup!.sourceWord;
    _error = null;
    _preferenceError = null;
    _loading = true;
    notifyListeners();
    try {
      final DictionaryCatalogue catalogue = await repository.catalogue(
        cancellation: request,
      );
      if (!_owner.owns(request)) return;
      _catalogue = catalogue;
      String? remembered;
      try {
        remembered = await preferences.dictionary(
          context.language,
          _lookup!.family,
        );
      } catch (error) {
        if (_owner.owns(request)) _preferenceError = error;
      }
      if (!_owner.owns(request)) return;
      final List<DictionaryModule> compatible = catalogue.modules
          .where(_compatible)
          .toList(growable: false);
      // A previously explicit cross-language choice is safe to restore; new
      // automatic defaults still require matching language and capability.
      final DictionaryModule? selected =
          catalogue.modules
              .where(
                (DictionaryModule item) =>
                    item.id == remembered && _compatibleFamily(item),
              )
              .firstOrNull ??
          compatible.firstOrNull;
      if (selected != null) await _loadModule(selected, request);
    } catch (error) {
      if (_owner.owns(request)) _error = error;
    } finally {
      if (_owner.owns(request)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  bool _compatible(DictionaryModule module) {
    if (_language(module.language) != _language(_context!.language)) {
      return false;
    }
    return _compatibleFamily(module);
  }

  bool _compatibleFamily(DictionaryModule module) {
    final List<String> strongs = _lookup!.strongs;
    return strongs.isEmpty
        ? module.strongPrefix == null
        : module.strongPrefix != null &&
              strongs.any((String id) => id.startsWith(module.strongPrefix!));
  }

  Future<void> selectModule(String id) async {
    final DictionaryModule? module = modules
        .where((DictionaryModule item) => item.id == id)
        .firstOrNull;
    if (module == null || _context == null) return;
    final RequestCancellation request = _owner.begin();
    _loading = true;
    _error = null;
    _preferenceError = null;
    _requestedEntry = null;
    _history.clear();
    _metadata = null;
    _index = null;
    _entry = null;
    _matches = const <DictionaryIndexEntry>[];
    _selected = module;
    notifyListeners();
    try {
      await _loadModule(module, request);
      if (!_owner.owns(request)) return;
      try {
        final String language = _context!.language;
        final String family = _lookup!.family;
        final Future<void> write = _preferenceTail.then((_) async {
          if (_owner.owns(request)) {
            await preferences.setDictionary(language, family, id);
          }
        });
        // A slow older storage write cannot finish after a newer preference.
        _preferenceTail = write.catchError((Object _) {});
        await write;
      } catch (error) {
        if (_owner.owns(request)) _preferenceError = error;
      }
    } catch (error) {
      if (_owner.owns(request)) _error = error;
    } finally {
      if (_owner.owns(request)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> _loadModule(
    DictionaryModule module,
    RequestCancellation request,
  ) async {
    _selected = module;
    final DictionaryMetadata metadata = await repository.metadata(
      module.id,
      cancellation: request,
    );
    request.throwIfCancelled();
    final DictionaryIndex index = await repository.index(
      module.id,
      cancellation: request,
    );
    if (!_owner.owns(request)) return;
    if (metadata.language != index.language ||
        metadata.entryCount != index.entries.length ||
        metadata.uniqueKeyCount != index.uniqueKeyCount) {
      throw const ApiFormatException(
        'The dictionary index and metadata are inconsistent. Please retry.',
      );
    }
    _metadata = metadata;
    _index = index;
    _matches = DictionaryIndexLookup.exact(index, _lookup!.candidates);
    _query = _lookup!.sourceWord;
    _entry = null;
    if (_matches.isNotEmpty) {
      final String id = _matches.first.id;
      _requestedEntry = id;
      final DictionaryEntry entry = await repository.entry(
        module.id,
        id,
        cancellation: request,
      );
      if (_owner.owns(request)) _entry = entry;
    }
  }

  /// Index filtering is local and never a server definition-text search.
  Future<void> searchIndex(String query) async {
    final RequestCancellation request = _owner.begin();
    final DictionaryIndex? index = _index;
    _loading = index != null;
    _error = null;
    _query = query;
    _matches = const <DictionaryIndexEntry>[];
    notifyListeners();
    if (index == null) return;
    try {
      final List<DictionaryIndexEntry> matches =
          await DictionaryIndexLookup.filterCooperatively(
            index,
            query,
            request,
          );
      if (_owner.owns(request)) _matches = matches;
    } catch (error) {
      if (_owner.owns(request)) _error = error;
    } finally {
      if (_owner.owns(request)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  Future<void> openEntry(String id) async {
    final DictionaryIndex? index = _index;
    final DictionaryModule? module = _selected;
    if (index == null || module == null) return;
    if (index.entryById(id) == null) {
      _owner.cancel();
      _loading = false;
      _requestedEntry = id;
      _error = const ReferenceLookupException(
        'This linked word is not in the dictionary index.',
      );
      notifyListeners();
      return;
    }
    if (_entry?.id == id && !_loading) return;
    final RequestCancellation request = _owner.begin();
    final int previous = _history.indexWhere(
      (DictionaryEntry item) => item.id == id,
    );
    if (previous >= 0) {
      _entry = _history[previous];
      _history.removeRange(previous, _history.length);
      _requestedEntry = id;
      _loading = false;
      _error = null;
      notifyListeners();
      return;
    }
    final DictionaryEntry? current = _entry;
    _requestedEntry = id;
    _loading = true;
    _error = null;
    notifyListeners();
    try {
      final DictionaryEntry result = await repository.entry(
        module.id,
        id,
        cancellation: request,
      );
      if (!_owner.owns(request)) return;
      if (current != null && current.id != id) {
        _history.add(current);
        if (_history.length > historyLimit) _history.removeAt(0);
      }
      _entry = result;
    } catch (error) {
      if (_owner.owns(request)) _error = error;
    } finally {
      if (_owner.owns(request)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  void goBack() {
    if (_history.isEmpty) return;
    _owner.cancel();
    _entry = _history.removeLast();
    _requestedEntry = _entry!.id;
    _loading = false;
    _error = null;
    notifyListeners();
  }

  Future<void> retry() async {
    if (_selected != null && _index != null && _requestedEntry != null) {
      // Clear the loaded entry so an explicit Retry really sends the request.
      final String id = _requestedEntry!;
      _entry = null;
      await openEntry(id);
    } else if (_selected != null) {
      await selectModule(_selected!.id);
    } else if (_context != null) {
      await open(_context!);
    }
  }

  void close() {
    _owner.cancel();
    _loading = false;
    _history.clear();
  }

  @override
  void dispose() {
    _owner.cancel();
    super.dispose();
  }
}

String _language(String value) {
  final String normalized = value
      .trim()
      .toLowerCase()
      .split(RegExp('[-_]'))
      .first;
  return const <String, String>{
        'english': 'en',
        'greek': 'el',
        'hebrew': 'he',
        'swedish': 'sv',
        'vietnamese': 'vi',
        'afrikaans': 'af',
        'german': 'de',
        'french': 'fr',
        'spanish': 'es',
        'portuguese': 'pt',
        'arabic': 'ar',
        'russian': 'ru',
        'chinese': 'zh',
        'japanese': 'ja',
        'korean': 'ko',
        'dutch': 'nl',
        'italian': 'it',
      }[normalized] ??
      normalized;
}
