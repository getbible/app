import 'package:flutter/foundation.dart';

import '../core/errors.dart';
import '../core/request_cancellation.dart';
import '../domain/models/dictionary.dart';
import '../domain/models/reference.dart';
import '../domain/models/service_envelopes.dart';
import '../domain/models/study_context.dart';
import '../domain/repositories/dictionary_repository.dart';
import '../domain/repositories/installed_study_resource.dart';
import '../domain/repositories/study_preferences_repository.dart';
import 'dictionary_discovery.dart';
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
  final RequestOwner _discoveryOwner = RequestOwner();
  late final DictionaryDiscovery _discovery = DictionaryDiscovery(repository);
  DictionaryDiscoveryResult? _discoveryResult;
  bool _discovering = false;
  bool _browsing = false;
  bool _includeOnline = false;
  bool _usingInstalledChoices = false;
  bool _onlineChoicesAvailable = false;
  bool get usingInstalledChoices => _usingInstalledChoices;
  bool get onlineChoicesAvailable => _onlineChoicesAvailable;
  String? _remembered;
  String? _manualModule;
  List<String> _candidates = const [];

  DictionaryDiscoveryResult? get discoveryResult => _discoveryResult;
  bool get isDiscovering => _discovering;
  bool get isBrowsing => _browsing;
  List<DictionaryModule> get choices => _browsing
      ? modules
      : (_discoveryResult?.matches.map((match) => match.module).toList() ??
            const []);
  ConfirmedDictionary? _confirmed(String id) => _discoveryResult?.matches
      .where((match) => match.module.id == id)
      .firstOrNull;

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
  bool isInstalled = false;
  bool _active = false;
  bool _disposed = false;
  int _installationStatusGeneration = 0;
  String? _requestedEntry;

  StudyContext? get context => _context;
  DictionaryLookup? get lookup => _lookup;
  List<DictionaryModule> get modules =>
      _catalogue?.modules.where((module) => module.entryCount > 0).toList() ??
      const <DictionaryModule>[];
  DictionaryModule? get selectedModule => _selected;
  DictionaryMetadata? get metadata => _metadata;
  DictionaryEntry? get entry => _entry;
  List<DictionaryIndexEntry> get matches => _matches;
  String get query => _query;
  Object? get error => _error;
  Object? get preferenceError => _preferenceError;
  bool get isLoading => _loading;
  bool get needsResourceChoice =>
      !_loading && !_discovering && _error == null && _selected == null;
  bool get canGoBack => _history.isNotEmpty;
  int get historyLength => _history.length;

  /// Refresh only installation availability; keep the selected definition,
  /// index results and navigation history intact while a download completes.
  Future<void> refreshInstallationStatus() async {
    _discovery.clearIndexes();
    final module = _selected;
    final context = _context;
    final capability = repository;
    if (!_active ||
        _disposed ||
        module == null ||
        capability is! InstalledStudyResource) {
      return;
    }
    final generation = ++_installationStatusGeneration;
    final installed = await (capability as InstalledStudyResource).isInstalled(
      module.id,
    );
    if (!_active ||
        _disposed ||
        generation != _installationStatusGeneration ||
        !identical(context, _context) ||
        !identical(module, _selected)) {
      return;
    }
    if (isInstalled != installed) {
      isInstalled = installed;
      notifyListeners();
    }
  }

  Future<void> open(StudyContext context) async {
    if (_disposed) return;
    _active = true;
    _includeOnline = false;
    _usingInstalledChoices = false;
    _onlineChoicesAvailable = false;
    _discoveryOwner.cancel();
    _discoveryResult = null;
    _discovering = false;
    _manualModule = null;
    _installationStatusGeneration++;
    final RequestCancellation request = _owner.begin();
    _context = context;
    _lookup = DictionaryLookupBuilder.fromContext(context);
    _candidates = _lookup!.candidates;
    _browsing = _candidates.isEmpty;
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
      _remembered = remembered;
      if (_browsing) {
        final selected = await _preferredForBrowsing(request);
        if (!_owner.owns(request)) return;
        if (selected != null) await _loadModule(selected, request);
      } else {
        _loading = false;
        await _discover();
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

  List<String> get _activeStrongs =>
      _query == _lookup?.sourceWord ? _lookup!.strongs : const [];

  Future<List<DictionaryModule>> _installedModules(
    List<DictionaryModule> choices,
    RequestCancellation request,
  ) async {
    final capability = repository;
    if (capability is! InstalledStudyResource) return const [];
    final installed = <DictionaryModule>[];
    for (final module in choices) {
      request.throwIfCancelled();
      if (await request.bind(
        (capability as InstalledStudyResource).isInstalled(module.id),
      )) {
        installed.add(module);
      }
    }
    request.throwIfCancelled();
    return installed;
  }

  /// Opening the browser or clearing a lookup must not contact an unrelated
  /// online resource when a complete dictionary is available on this device.
  /// The full catalogue remains available for an explicit resource choice.
  Future<DictionaryModule?> _preferredForBrowsing(
    RequestCancellation request,
  ) async {
    final choices = modules;
    final installed = await _installedModules(choices, request);
    return _preferred(installed.isEmpty ? choices : installed);
  }

  DictionaryModule? _preferred(List<DictionaryModule> choices) {
    final manual = choices
        .where((module) => module.id == _manualModule)
        .firstOrNull;
    if (manual != null) return manual;
    final previous = choices
        .where((module) => module.id == _remembered)
        .firstOrNull;
    if (previous != null &&
        (_activeStrongs.isEmpty || _compatibleFamily(previous))) {
      return previous;
    }
    int score(DictionaryModule module) {
      final language = _language(module.language);
      final lexical =
          module.strongPrefix != null &&
          _activeStrongs.any((id) => id.startsWith(module.strongPrefix!));
      return (lexical ? 1000 : 0) +
          (language == _language(_context!.language)
              ? 500
              : language == 'en'
              ? 100
              : 0) +
          (_activeStrongs.isEmpty && module.strongPrefix == null ? 50 : 0) +
          ({'easton', 'strongsgreek', 'strongshebrew'}.contains(module.id)
              ? 10
              : 0);
    }

    final ranked = choices.where((module) => module.entryCount > 0).toList()
      ..sort((a, b) {
        final order = score(b).compareTo(score(a));
        return order != 0 ? order : a.name.compareTo(b.name);
      });
    return ranked.firstOrNull;
  }

  Future<void> _discover() async {
    final request = _discoveryOwner.begin();
    _owner.cancel();
    _discovering = true;
    _loading = false;
    _error = null;
    final ordered = modules.toList()
      ..sort((a, b) {
        int rank(DictionaryModule module) =>
            module.id == (_manualModule ?? _remembered)
            ? 0
            : _compatible(module)
            ? 1
            : 2;
        return rank(a).compareTo(rank(b));
      });
    notifyListeners();
    try {
      final capability = repository;
      var resources = ordered;
      _usingInstalledChoices = false;
      _onlineChoicesAvailable = false;
      if (!_includeOnline) {
        final installed = await _installedModules(ordered, request);
        if (installed.isNotEmpty) {
          resources = installed;
          _usingInstalledChoices = true;
          _onlineChoicesAvailable = installed.length < ordered.length;
          notifyListeners();
        }
      }
      if (capability is DictionaryLookupSession) {
        (capability as DictionaryLookupSession).beginLookup();
      }
      _discoveryResult = await _discovery.lookup(
        modules: resources,
        publication: _catalogue?.source.toString(),
        candidates: _candidates,
        query: _query,
        cancellation: request,
        onProgress: (result) {
          if (!_discoveryOwner.owns(request) || _disposed) return;
          _discoveryResult = result;
          notifyListeners();
        },
      );
      if (!_discoveryOwner.owns(request) || _disposed) return;
      // A choice made while discovery was progressing owns the active entry.
      if (_selected == null) {
        final selected = _preferred(choices);
        if (selected != null) {
          final selection = _owner.begin();
          _loading = true;
          try {
            await _loadModule(selected, selection);
          } catch (error) {
            if (_owner.owns(selection)) _error = error;
          } finally {
            if (_owner.owns(selection)) _loading = false;
          }
        }
      }
    } on RequestCancelledException {
      // New lookup, dismissal or disposal owns the replacement state.
    } catch (error) {
      if (_discoveryOwner.owns(request)) _error = error;
    } finally {
      if (_discoveryOwner.owns(request) && !_disposed) {
        _discovering = false;
        notifyListeners();
      }
    }
  }

  /// Searches all resources for a changed word, retaining captured Scripture
  /// context for citation previews. Clearing the term enters explicit browsing.
  Future<void> searchWords(String query, {bool preserveChoice = false}) async {
    if (!_active || _disposed || _catalogue == null) return;
    if (query.length > 500) {
      _error = const FormatException(
        'Dictionary lookup is limited to 500 characters.',
      );
      notifyListeners();
      return;
    }
    final previousChoice = preserveChoice
        ? (_manualModule ?? _selected?.id)
        : null;
    _owner.cancel();
    _discoveryOwner.cancel();
    _query = query;
    _candidates = query == _lookup?.sourceWord ? _lookup!.candidates : [query];
    _browsing = query.trim().isEmpty;
    _selected = null;
    _metadata = null;
    _index = null;
    _entry = null;
    _history.clear();
    _requestedEntry = null;
    _matches = const [];
    _manualModule = previousChoice;
    _discoveryResult = null;
    _error = null;
    if (_browsing) {
      _discovering = false;
      final request = _owner.begin();
      try {
        final selected = await _preferredForBrowsing(request);
        if (!_owner.owns(request)) return;
        if (selected != null) {
          await selectModule(selected.id);
        } else {
          notifyListeners();
        }
      } catch (error) {
        if (_owner.owns(request)) {
          _error = error;
          notifyListeners();
        }
      }
    } else {
      await _discover();
    }
  }

  Future<void> includeOnlineDictionaries() {
    _includeOnline = true;
    return retryDiscovery();
  }

  Future<void> retryDiscovery() => searchWords(_query, preserveChoice: true);

  Future<void> openSuggestion(DictionarySuggestion suggestion) async {
    if (!_active || _disposed) return;
    _discoveryOwner.cancel();
    _discovering = false;
    _browsing = true;
    _query = suggestion.entry.key;
    _candidates = [suggestion.entry.id];
    await selectModule(suggestion.module.id);
    if (_selected?.id == suggestion.module.id && _active && !_disposed) {
      await openEntry(suggestion.entry.id);
    }
  }

  bool _compatible(DictionaryModule module) {
    if (_language(module.language) != _language(_context!.language)) {
      return false;
    }
    return _compatibleFamily(module);
  }

  bool _compatibleFamily(DictionaryModule module) {
    final List<String> strongs = _activeStrongs;
    return strongs.isEmpty
        ? module.strongPrefix == null
        : module.strongPrefix != null &&
              strongs.any((String id) => id.startsWith(module.strongPrefix!));
  }

  Future<void> selectModule(String id) async {
    final DictionaryModule? module = modules
        .where((DictionaryModule item) => item.id == id)
        .firstOrNull;
    if (module == null || _context == null || !_active || _disposed) return;
    _manualModule = id;
    if (!_browsing && _confirmed(id) == null) _browsing = true;
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
        final String family = _activeStrongs.isEmpty
            ? 'surface'
            : _lookup!.family;
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
    final statusGeneration = ++_installationStatusGeneration;
    isInstalled = false;
    final capability = repository;
    if (capability is InstalledStudyResource) {
      final installed = await (capability as InstalledStudyResource)
          .isInstalled(module.id);
      if (!_owner.owns(request)) return;
      if (statusGeneration == _installationStatusGeneration) {
        isInstalled = installed;
      }
    }
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
    final confirmed = !_browsing ? _confirmed(module.id) : null;
    _matches = confirmed == null
        ? await DictionaryIndexLookup.exactCooperatively(
            index,
            _candidates,
            request,
          )
        : confirmed.definitions
              .map((entry) => index.entryById(entry.id))
              .nonNulls
              .toList();
    if (!_owner.owns(request)) return;
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
    _active = false;
    _installationStatusGeneration++;
    _owner.cancel();
    _discoveryOwner.cancel();
    _discovering = false;
    _loading = false;
    _history.clear();
  }

  @override
  void dispose() {
    _disposed = true;
    _active = false;
    _installationStatusGeneration++;
    _owner.cancel();
    _discoveryOwner.cancel();
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
