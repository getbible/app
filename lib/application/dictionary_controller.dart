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
    this.captureResourceUse,
  }) {
    if (historyLimit < 1 || historyLimit > 32) {
      throw ArgumentError.value(historyLimit, 'historyLimit');
    }
  }
  final DictionaryRepository repository;
  final StudyPreferencesRepository preferences;
  final int historyLimit;

  /// Captures a success callback when a reader action begins. Composition can
  /// invalidate earlier actions when downloads are cleared, without coupling
  /// dictionary navigation to the download coordinator.
  final ValueChanged<String> Function()? captureResourceUse;
  ValueChanged<String>? _resourceOpened;
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
  final List<_DictionaryLookupState> _lookupHistory = [];
  List<DictionaryEntry> _definitions = const [];
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

  /// Every confirmed definition for the selected resource, in published order.
  List<DictionaryEntry> get definitions => _definitions;
  List<DictionaryIndexEntry> get matches => _matches;
  String get query => _query;
  Object? get error => _error;
  Object? get preferenceError => _preferenceError;
  bool get isLoading => _loading;
  bool get needsResourceChoice =>
      !_loading && !_discovering && _error == null && _selected == null;
  bool get canGoBack => _history.isNotEmpty || _lookupHistory.isNotEmpty;
  int get historyLength => _history.length + _lookupHistory.length;
  bool get canBrowse => _lookup?.candidates.isEmpty ?? true;

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
    _resourceOpened = captureResourceUse?.call();
    _active = true;
    _lookupHistory.clear();
    _definitions = const [];
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
    Future<void>? initialSelection;
    Future<void> loadFirstChoice(DictionaryModule module) async {
      final selection = _owner.begin();
      _error = null;
      _loading = true;
      try {
        await _loadModule(module, selection);
      } on RequestCancelledException {
        // A user choice or a newer lookup owns the replacement.
      } catch (error) {
        if (_owner.owns(selection)) _error = error;
      } finally {
        if (_owner.owns(selection) && !_disposed) {
          _loading = false;
          notifyListeners();
        }
      }
    }

    void chooseFirstResult() {
      final selected = _preferred(choices);
      if (selected == null || selected.id == _selected?.id) return;
      // Progressive results can improve the automatic language/lexical default,
      // but never replace a resource the reader chose or an entry they opened.
      if (_selected != null &&
          (_history.isNotEmpty ||
              (_manualModule != null && selected.id != _manualModule))) {
        return;
      }
      initialSelection = loadFirstChoice(selected);
    }

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
          chooseFirstResult();
          notifyListeners();
        },
      );
      if (!_discoveryOwner.owns(request) || _disposed) return;
      // Show usable content before a slower unrelated dictionary finishes.
      // An explicit resource choice is retained as other results arrive.
      chooseFirstResult();
      await initialSelection;
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
  /// context for citation previews. An empty contextual lookup restores the
  /// original selection; only an unbound dictionary browser lists all modules.
  Future<void> searchWords(String query, {bool preserveChoice = false}) =>
      _searchWords(query, preserveChoice: preserveChoice);

  Future<void> _searchWords(
    String query, {
    bool preserveChoice = false,
    String? preferredModule,
    List<String> exactCandidates = const [],
    _DictionaryLookupState? previousLookup,
  }) async {
    if (!_active || _disposed || _catalogue == null) return;
    if (query.trim().isEmpty && !canBrowse) query = _lookup!.sourceWord;
    if (query.length > 500) {
      _error = const FormatException(
        'Dictionary lookup is limited to 500 characters.',
      );
      notifyListeners();
      return;
    }
    _resourceOpened = captureResourceUse?.call();
    final previousChoice =
        preferredModule ??
        (preserveChoice ? (_manualModule ?? _selected?.id) : null);
    if (previousLookup == null) {
      _lookupHistory.clear();
    } else {
      // History belongs to the navigation action, not to eventual network
      // completion. Back is usable during discovery, and another linked lookup
      // cannot cancel away its predecessor's snapshot.
      _lookupHistory.add(previousLookup);
      if (_lookupHistory.length > historyLimit) _lookupHistory.removeAt(0);
    }
    _owner.cancel();
    _discoveryOwner.cancel();
    _query = query;
    _candidates = exactCandidates.isNotEmpty
        ? exactCandidates
        : query == _lookup?.sourceWord
        ? _lookup!.candidates
        : [query];
    _browsing = canBrowse && query.trim().isEmpty;
    _selected = null;
    _metadata = null;
    _index = null;
    _entry = null;
    _definitions = const [];
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
          await _selectModule(selected.id, captureUse: false);
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
    await _followLookup(suggestion.module.id, suggestion.entry);
  }

  /// A related word is a new contextual lookup, not a switch into browsing.
  /// The exact published ID participates alongside its display key, preserving
  /// duplicate entries and lexical identifiers without guessing document URLs.
  Future<void> followLink(String id) async {
    final target = _index?.entryById(id);
    final module = _selected;
    if (target == null || module == null) {
      await openEntry(id); // Existing missing-link validation never sends HTTP.
      return;
    }
    await _followLookup(module.id, target);
  }

  Future<void> _followLookup(String module, DictionaryIndexEntry target) async {
    if (!_active || _disposed) return;
    final previous = _DictionaryLookupState.capture(this);
    await _searchWords(
      target.key,
      preferredModule: module,
      exactCandidates: [target.id, target.key],
      previousLookup: previous,
    );
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

  Future<void> selectModule(String id) => _selectModule(id);

  Future<void> _selectModule(String id, {bool captureUse = true}) async {
    final DictionaryModule? module = modules
        .where((DictionaryModule item) => item.id == id)
        .firstOrNull;
    if (module == null || _context == null || !_active || _disposed) return;
    if (!_browsing && _confirmed(id) == null) return;
    // An internal continuation keeps the initiating action's callback, so a
    // delayed preference read cannot undo a later Clear downloads operation.
    if (captureUse) _resourceOpened = captureResourceUse?.call();
    _manualModule = id;
    final RequestCancellation request = _owner.begin();
    _loading = true;
    _error = null;
    _preferenceError = null;
    _requestedEntry = null;
    _history.clear();
    _metadata = null;
    _index = null;
    _entry = null;
    _definitions = const [];
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
    try {
      await _loadModuleGeneration(module, request);
    } on InstalledStudyGenerationChanged {
      request.throwIfCancelled();
      await _loadModuleGeneration(module, request);
    }
  }

  Future<void> _loadModuleGeneration(
    DictionaryModule module,
    RequestCancellation request,
  ) async {
    _selected = module;
    _metadata = null;
    _index = null;
    _entry = null;
    _definitions = const [];
    _matches = const [];
    _requestedEntry = null;
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
    _definitions = const [];
    // Re-read from the active repository generation. Discovery bodies must not
    // leak across an installed-resource update while the chooser is open.
    try {
      for (final match in _matches) {
        _requestedEntry ??= match.id;
        final DictionaryEntry entry = await repository.entry(
          module.id,
          match.id,
          cancellation: request,
        );
        if (!_owner.owns(request)) return;
        if (entry.text.trim().isEmpty) continue;
        _entry ??= entry;
        _definitions = List.unmodifiable([..._definitions, entry]);
        notifyListeners();
      }
    } catch (_) {
      // A partial multi-definition load must retry the module, not reopen its
      // first successful entry and silently discard the remaining matches.
      if (_owner.owns(request)) _requestedEntry = null;
      rethrow;
    }
    if (_owner.owns(request)) _resourceOpened?.call(module.id);
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
    final resourceOpened = captureResourceUse?.call();
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
      _definitions = [_entry!];
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
      DictionaryEntry result;
      try {
        result = await repository.entry(module.id, id, cancellation: request);
      } on InstalledStudyGenerationChanged {
        result = await _reloadEntryGeneration(module, id, request);
      }
      if (!_owner.owns(request)) return;
      if (current != null && current.id != id) {
        _history.add(current);
        if (_history.length > historyLimit) _history.removeAt(0);
      }
      _entry = result;
      _definitions = [result];
      resourceOpened?.call(module.id);
    } catch (error) {
      if (_owner.owns(request)) _error = error;
    } finally {
      if (_owner.owns(request)) {
        _loading = false;
        notifyListeners();
      }
    }
  }

  /// Keep the current definition visible until one complete replacement read
  /// succeeds. A second concurrent activation propagates an honest retry state;
  /// it never loops or substitutes another entry for a removed identifier.
  Future<DictionaryEntry> _reloadEntryGeneration(
    DictionaryModule module,
    String id,
    RequestCancellation request,
  ) async {
    final metadata = await repository.metadata(
      module.id,
      cancellation: request,
    );
    request.throwIfCancelled();
    final index = await repository.index(module.id, cancellation: request);
    request.throwIfCancelled();
    if (metadata.language != index.language ||
        metadata.entryCount != index.entries.length ||
        metadata.uniqueKeyCount != index.uniqueKeyCount) {
      throw const ApiFormatException(
        'The dictionary index and metadata are inconsistent. Please retry.',
      );
    }
    if (index.entryById(id) == null) {
      throw const ReferenceLookupException(
        'This linked word is not in the dictionary index.',
      );
    }
    final entry = await repository.entry(module.id, id, cancellation: request);
    request.throwIfCancelled();
    if (_owner.owns(request)) {
      _metadata = metadata;
      _index = index;
      _matches = _matches
          .map((match) => index.entryById(match.id))
          .nonNulls
          .toList();
      _discovery.clearIndexes();
    }
    return entry;
  }

  void goBack() {
    if (_history.isEmpty) {
      if (_lookupHistory.isEmpty) return;
      _owner.cancel();
      _discoveryOwner.cancel();
      final previous = _lookupHistory.removeLast();
      previous.restore(this);
      _discovering = false;
      _loading = false;
      _error = null;
      notifyListeners();
      return;
    }
    _owner.cancel();
    _entry = _history.removeLast();
    _definitions = [_entry!];
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
    _lookupHistory.clear();
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

/// Bounded navigation snapshots restore the complete visible lookup, including
/// its filtered chooser, instead of showing an old entry under a new word.
final class _DictionaryLookupState {
  _DictionaryLookupState.capture(DictionaryController controller)
    : query = controller._query,
      candidates = controller._candidates,
      result = controller._discoveryResult,
      module = controller._selected,
      metadata = controller._metadata,
      index = controller._index,
      entry = controller._entry,
      definitions = controller._definitions,
      matches = controller._matches,
      history = List.of(controller._history),
      browsing = controller._browsing,
      installed = controller.isInstalled,
      manualModule = controller._manualModule,
      requestedEntry = controller._requestedEntry;

  final String query;
  final List<String> candidates;
  final DictionaryDiscoveryResult? result;
  final DictionaryModule? module;
  final DictionaryMetadata? metadata;
  final DictionaryIndex? index;
  final DictionaryEntry? entry;
  final List<DictionaryEntry> definitions, history;
  final List<DictionaryIndexEntry> matches;
  final bool browsing, installed;
  final String? manualModule, requestedEntry;

  void restore(DictionaryController controller) {
    controller
      .._query = query
      .._candidates = candidates
      .._discoveryResult = result
      .._selected = module
      .._metadata = metadata
      .._index = index
      .._entry = entry
      .._definitions = definitions
      .._matches = matches
      .._browsing = browsing
      ..isInstalled = installed
      .._manualModule = manualModule
      .._requestedEntry = requestedEntry;
    controller._history
      ..clear()
      ..addAll(history);
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
