import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/dictionary_controller.dart';
import 'package:getbible/core/request_cancellation.dart';
import 'package:getbible/domain/models/dictionary.dart';
import 'package:getbible/domain/models/service_envelopes.dart';
import 'package:getbible/domain/models/study_context.dart';
import 'package:getbible/domain/repositories/dictionary_repository.dart';
import 'package:getbible/domain/repositories/installed_study_resource.dart';

import 'support/dictionary_fixture.dart';

void main() {
  test(
    'Retry completes every confirmed definition after a later entry read fails',
    () async {
      final fixture = DictionaryFixture();
      final repository = _ControlledDictionaryRepository(fixture.repository)
        ..before = (kind, module, id, count) async {
          if (kind == 'entry' && id == 'G3056--2' && count == 2) {
            throw const FormatException('Temporary second-definition failure');
          }
        };
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: ['G3056']));
      expect(controller.error, isNotNull);
      expect(controller.definitions.map((entry) => entry.id), ['G3056']);
      await controller.retry();
      expect(controller.error, isNull);
      expect(controller.definitions.map((entry) => entry.id), [
        'G3056',
        'G3056--2',
      ]);
      expect(controller.query, 'Word');
    },
  );

  test(
    'Back restores the previous lookup while a linked definition is pending',
    () async {
      final fixture = DictionaryFixture();
      final repository = DelayedDictionaryRepository(fixture.repository);
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: ['G3056']));
      repository.delayEntry = 'G4487';
      final linked = controller.followLink('G4487');
      await repository.entryStarted.future;
      expect(controller.canGoBack, isTrue);
      controller.goBack();
      expect(controller.query, 'Word');
      expect(controller.definitions.map((entry) => entry.id), [
        'G3056',
        'G3056--2',
      ]);
      repository.entryPending.complete(
        await fixture.repository.entry('strongsgreek', 'G4487'),
      );
      await linked;
      expect(controller.query, 'Word');
      expect(controller.canGoBack, isFalse);
      expect(controller.isDiscovering, isFalse);
    },
  );

  test(
    'nested progressive links retain each prior word before discovery completes',
    () async {
      final fixture = DictionaryFixture();
      final repository = _ControlledDictionaryRepository(fixture.repository);
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: ['G3056']));
      // Invalidate only discovery's index cache so one unrelated index remains
      // pending across both navigations, while the selected definitions arrive.
      await controller.refreshInstallationStatus();
      final entered = Completer<void>();
      final release = Completer<void>();
      repository.before = (kind, module, id, count) async {
        if (kind == 'index' && module == 'oddgreek') {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        }
      };
      final first = controller.followLink('G4487');
      await entered.future;
      await _waitForEntry(controller, 'G4487');
      expect(controller.isDiscovering, isTrue);
      expect(controller.historyLength, 1);
      final second = controller.followLink('G3056');
      await _waitForEntry(controller, 'G3056');
      expect(controller.isDiscovering, isTrue);
      expect(controller.historyLength, 2);
      controller.goBack();
      expect(controller.query, 'ῥῆμα');
      expect(controller.definitions.single.id, 'G4487');
      controller.goBack();
      expect(controller.query, 'Word');
      expect(controller.definitions.map((entry) => entry.id), [
        'G3056',
        'G3056--2',
      ]);
      release.complete();
      await Future.wait([first, second]);
      expect(controller.query, 'Word');
      expect(controller.canGoBack, isFalse);
    },
  );

  test(
    'an unavailable linked word retains Back without fabricating a definition',
    () async {
      final fixture = DictionaryFixture();
      final repository = _ControlledDictionaryRepository(fixture.repository);
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: ['G3056']));
      repository.before = (kind, module, id, count) async {
        if (kind == 'entry' && id == 'G4487') {
          throw const FormatException('Temporary failure');
        }
      };
      await controller.followLink('G4487');
      expect(controller.choices, isEmpty);
      expect(controller.definitions, isEmpty);
      expect(controller.canGoBack, isTrue);
      controller.goBack();
      expect(controller.query, 'Word');
      expect(controller.definitions.map((entry) => entry.id), [
        'G3056',
        'G3056--2',
      ]);
    },
  );

  test(
    'a newer word cancels a related lookup without restoring stale history',
    () async {
      final fixture = DictionaryFixture();
      final repository = DelayedDictionaryRepository(fixture.repository);
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: ['G3056']));
      repository.delayEntry = 'G4487';
      final older = controller.followLink('G4487');
      await repository.entryStarted.future;
      await controller.searchWords('Kadesh');
      repository.entryPending.complete(
        await fixture.repository.entry('strongsgreek', 'G4487'),
      );
      await older;
      expect(controller.query, 'Kadesh');
      expect(controller.selectedModule!.id, 'easton');
      expect(controller.definitions.first.id, 'kadesh');
      expect(controller.canGoBack, isFalse);
      expect(controller.isBrowsing, isFalse);
    },
  );

  test(
    'contextual suggestions and links keep confirmed choices and restore history',
    () async {
      final fixture = DictionaryFixture();
      final controller = DictionaryController(
        repository: fixture.repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: ['G3056']));
      expect(controller.definitions.map((entry) => entry.id), [
        'G3056',
        'G3056--2',
      ]);
      await controller.followLink('G4487');
      expect(controller.query, 'ῥῆμα');
      expect(controller.isBrowsing, isFalse);
      expect(controller.choices.map((module) => module.id), ['strongsgreek']);
      expect(controller.definitions.single.text, 'A saying.');
      controller.goBack();
      expect(controller.query, 'Word');
      expect(controller.definitions.map((entry) => entry.id), [
        'G3056',
        'G3056--2',
      ]);
      expect(
        controller.choices.map((module) => module.id),
        isNot(contains('oddgreek')),
      );
      await controller.searchWords('Kad');
      expect(controller.choices, isEmpty);
      final suggestion = controller.discoveryResult!.suggestions.first;
      await controller.openSuggestion(suggestion);
      expect(controller.isBrowsing, isFalse);
      expect(controller.selectedModule!.id, 'easton');
      expect(controller.choices.map((module) => module.id), ['easton']);
      expect(controller.definitions, isNotEmpty);
      await controller.searchWords('');
      expect(controller.isBrowsing, isFalse);
      expect(controller.query, 'Word');
      expect(
        controller.choices.map((module) => module.id),
        isNot(contains('oddgreek')),
      );
    },
  );

  test(
    'a confirmed definition appears while an unrelated dictionary is pending',
    () async {
      final fixture = DictionaryFixture();
      final repository = DelayedDictionaryRepository(fixture.repository)
        ..delayModule = 'oddgreek';
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      final lookup = controller.open(dictionaryContext(strongs: ['G3056']));
      await repository.started.future;
      for (
        var attempt = 0;
        attempt < 100 && controller.definitions.isEmpty;
        attempt++
      ) {
        await Future<void>.delayed(Duration.zero);
      }
      expect(controller.isDiscovering, isTrue);
      expect(controller.definitions, isNotEmpty);
      repository.pending.complete(await fixture.repository.index('oddgreek'));
      await lookup;
      expect(controller.selectedModule!.id, 'strongsgreek');
      expect(controller.definitions.map((entry) => entry.id), [
        'G3056',
        'G3056--2',
      ]);
    },
  );

  test(
    'installation status refresh preserves the current dictionary entry and history',
    () async {
      final fixture = DictionaryFixture();
      final repository = DelayedDictionaryRepository(fixture.repository);
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: ['G3056']));
      await controller.openEntry('G3056--2');
      final entry = controller.entry;
      final history = controller.historyLength;
      final requests = fixture.requests.length;
      repository.installed = true;
      await controller.refreshInstallationStatus();
      expect(controller.isInstalled, isTrue);
      expect(controller.entry, same(entry));
      expect(controller.historyLength, history);
      expect(fixture.requests.length, requests);
      repository.statusPending = Completer<bool>();
      final stale = controller.refreshInstallationStatus();
      controller.close();
      repository.statusPending!.complete(false);
      await stale;
      expect(
        controller.isInstalled,
        isTrue,
        reason: 'Dismissed status reads cannot update controller state.',
      );
    },
  );

  test('the latest dictionary installation refresh owns its result', () async {
    final fixture = DictionaryFixture();
    final repository = DelayedDictionaryRepository(fixture.repository);
    final controller = DictionaryController(
      repository: repository,
      preferences: MemoryStudyPreferences(),
    );
    addTearDown(() {
      controller.dispose();
      fixture.close();
    });
    await controller.open(dictionaryContext(strongs: ['G3056']));
    final pending = Completer<bool>();
    repository.statusPending = pending;
    final older = controller.refreshInstallationStatus();
    repository.statusPending = null;
    repository.installed = false;
    await controller.refreshInstallationStatus();
    pending.complete(true);
    await older;
    expect(controller.isInstalled, isFalse);
  });

  test(
    'lookup shows duplicate definitions and every Strong ID without bulk requests',
    () async {
      final DictionaryFixture fixture = DictionaryFixture();
      final DictionaryController controller = DictionaryController(
        repository: fixture.repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(
        dictionaryContext(strongs: <String>['G3056', 'G4487']),
      );
      expect(
        controller.matches.map((DictionaryIndexEntry item) => item.id),
        <String>['G3056', 'G3056--2', 'G4487'],
      );
      expect(controller.entry!.id, 'G3056');
      await controller.openEntry('G3056--2');
      expect(controller.entry!.text, 'A distinct definition.');
      expect(
        fixture.requests.any((Uri uri) => uri.path == '/v1/strongsgreek.json'),
        isFalse,
      );
    },
  );

  test(
    'confirmed foreign-language fallback stays attributed and an explicit choice is retained',
    () async {
      final DictionaryFixture fixture = DictionaryFixture();
      final MemoryStudyPreferences preferences = MemoryStudyPreferences();
      final DictionaryController controller = DictionaryController(
        repository: fixture.repository,
        preferences: preferences,
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      final StudyContext context = dictionaryContext(
        word: 'Kádésh,',
        language: 'ar',
      );
      await controller.open(context);
      expect(controller.selectedModule!.id, 'easton');
      expect(controller.entry, isNotNull);
      expect(controller.metadata!.language, 'en');
      expect(controller.choices.map((module) => module.id), contains('easton'));
      expect(
        fixture.requests.any((uri) => uri.path.endsWith('/index.json')),
        isTrue,
      );
      await controller.selectModule('easton');
      expect(controller.metadata!.language, 'en');
      expect(controller.matches.length, 2);
      expect(preferences.dictionaries['ar:surface'], 'easton');
      await controller.open(context);
      expect(controller.selectedModule!.id, 'easton');
    },
  );

  test(
    'Strong prefix cannot fabricate addresses absent from selected index',
    () async {
      final DictionaryFixture fixture = DictionaryFixture();
      final DictionaryController controller = DictionaryController(
        repository: fixture.repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: <String>['G3056']));
      await controller.selectModule('oddgreek');
      expect(
        controller.selectedModule!.id,
        'strongsgreek',
        reason: 'A contextual lookup cannot select an unconfirmed module.',
      );
      await controller.open(_browserContext());
      await controller.selectModule('oddgreek');
      expect(controller.matches, isEmpty);
      expect(controller.entry, isNull);
      expect(
        fixture.requests.any(
          (Uri uri) => uri.path == '/v1/oddgreek/G3056.json',
        ),
        isFalse,
      );
      await controller.searchIndex('álpha');
      expect(controller.matches.single.id, 'published-lemma');
      await controller.openEntry(controller.matches.single.id);
      expect(controller.entry!.id, 'published-lemma');
    },
  );

  test(
    'cyclic links reuse loaded history; missing links do not issue HTTP',
    () async {
      final DictionaryFixture fixture = DictionaryFixture();
      final DictionaryController controller = DictionaryController(
        repository: fixture.repository,
        preferences: MemoryStudyPreferences(),
        historyLimit: 2,
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: <String>['G3056']));
      await controller.openEntry('G4487');
      expect(controller.canGoBack, isTrue);
      final int requests = fixture.requests.length;
      await controller.openEntry('G3056');
      expect(controller.entry!.id, 'G3056');
      expect(controller.historyLength, 0);
      expect(fixture.requests.length, requests);
      await controller.openEntry('missing');
      expect(controller.error, isNotNull);
      expect(fixture.requests.length, requests);
      expect(controller.entry!.id, 'G3056');
    },
  );

  test(
    'late module and dismissed entry responses never replace current state',
    () async {
      final DictionaryFixture fixture = DictionaryFixture();
      final DelayedDictionaryRepository repository =
          DelayedDictionaryRepository(fixture.repository);
      final DictionaryController controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: <String>['G3056']));
      await controller.open(_browserContext());
      repository.delayModule = 'oddgreek';
      final Future<void> old = controller.selectModule('oddgreek');
      await repository.started.future;
      await controller.selectModule('strongshebrew');
      expect(controller.selectedModule!.id, 'strongshebrew');
      repository.pending.complete(await fixture.repository.index('oddgreek'));
      await old;
      expect(controller.selectedModule!.id, 'strongshebrew');
      expect(controller.metadata!.id, 'strongshebrew');
      expect(controller.entry, isNull);
    },
  );

  test(
    'choosing a confirmed resource during discovery preserves selection and context',
    () async {
      final fixture = DictionaryFixture();
      final repository = DelayedDictionaryRepository(fixture.repository)
        ..delayModule = 'oddgreek';
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      final context = dictionaryContext(strongs: ['G3056']);
      final lookup = controller.open(context);
      await repository.started.future;
      await Future<void>.delayed(Duration.zero);
      expect(controller.isDiscovering, isTrue);
      expect(
        controller.choices.map((module) => module.id),
        contains('strongsgreek'),
      );
      await controller.selectModule('strongsgreek');
      await controller.openEntry('G3056--2');
      final entry = controller.entry;
      repository.pending.complete(await fixture.repository.index('oddgreek'));
      await lookup;
      expect(controller.entry, same(entry));
      expect(controller.context, same(context));
      expect(controller.historyLength, 1);
      expect(controller.isDiscovering, isFalse);
    },
  );

  test(
    'new word cancels discovery and never keeps old lexical candidates',
    () async {
      final fixture = DictionaryFixture();
      final repository = DelayedDictionaryRepository(fixture.repository)
        ..delayModule = 'oddgreek';
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      final older = controller.open(dictionaryContext(strongs: ['G3056']));
      await repository.started.future;
      repository.delayModule = null;
      await controller.searchWords('Kadesh');
      final current = controller.entry;
      expect(current!.id, 'kadesh');
      expect(controller.selectedModule!.id, 'easton');
      repository.pending.complete(await fixture.repository.index('oddgreek'));
      await older;
      expect(controller.entry, same(current));
      expect(controller.choices.map((module) => module.id), ['easton']);
    },
  );

  test(
    'installed discovery remains local until online expansion is explicit',
    () async {
      final fixture = DictionaryFixture();
      final repository = DelayedDictionaryRepository(fixture.repository)
        ..installedIds.add('strongsgreek');
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences(),
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      await controller.open(dictionaryContext(strongs: ['G3056']));
      expect(controller.usingInstalledChoices, isTrue);
      expect(controller.onlineChoicesAvailable, isTrue);
      expect(
        fixture.requests
            .where((uri) => uri.path.endsWith('/index.json'))
            .map((uri) => uri.path),
        ['/v1/strongsgreek/index.json'],
      );
      await controller.includeOnlineDictionaries();
      expect(controller.usingInstalledChoices, isFalse);
      expect(
        fixture.requests.any((uri) => uri.path == '/v1/easton/index.json'),
        isTrue,
      );
      expect(controller.selectedModule!.id, 'strongsgreek');
    },
  );

  test('failed preference write retains usable definition', () async {
    final DictionaryFixture fixture = DictionaryFixture();
    final MemoryStudyPreferences preferences = MemoryStudyPreferences()
      ..failWrites = true;
    final DictionaryController controller = DictionaryController(
      repository: fixture.repository,
      preferences: preferences,
    );
    addTearDown(() {
      controller.dispose();
      fixture.close();
    });
    await controller.open(dictionaryContext(word: 'Kadesh'));
    await controller.selectModule('easton');
    expect(controller.entry!.id, 'kadesh');
    expect(controller.preferenceError, isNotNull);
    expect(controller.error, isNull);
  });

  test(
    'opening or returning to dictionary browsing prefers an installed resource',
    () async {
      final fixture = DictionaryFixture();
      final repository = DelayedDictionaryRepository(fixture.repository)
        ..installedIds.add('strongsgreek');
      final controller = DictionaryController(
        repository: repository,
        preferences: MemoryStudyPreferences()
          ..dictionaries['en:surface'] = 'easton',
      );
      addTearDown(() {
        controller.dispose();
        fixture.close();
      });
      final source = dictionaryContext();
      await controller.open(
        StudyContext(
          passage: source.passage,
          bookName: source.bookName,
          language: source.language,
          verse: source.verse,
        ),
      );
      expect(controller.isBrowsing, isTrue);
      expect(controller.selectedModule!.id, 'strongsgreek');
      expect(controller.isInstalled, isTrue);
      expect(controller.choices.map((module) => module.id), contains('easton'));
      await controller.searchWords('G3056');
      expect(controller.entry!.id, 'G3056');
      await controller.searchWords('');
      expect(controller.isBrowsing, isTrue);
      expect(controller.selectedModule!.id, 'strongsgreek');
      expect(
        fixture.requests.map((uri) => uri.path),
        everyElement(
          anyOf('/v1/dictionaries.json', startsWith('/v1/strongsgreek/')),
        ),
        reason: 'Automatic defaults must never request an online-only module.',
      );
      // A deliberate online choice remains possible from the full catalogue.
      await controller.selectModule('easton');
      expect(controller.selectedModule!.id, 'easton');
      expect(controller.metadata!.id, 'easton');
    },
  );

  test('a dismissed late entry cannot reopen the dictionary', () async {
    final DictionaryFixture fixture = DictionaryFixture();
    final DelayedDictionaryRepository repository = DelayedDictionaryRepository(
      fixture.repository,
    )..delayEntry = 'G4487';
    final DictionaryController controller = DictionaryController(
      repository: repository,
      preferences: MemoryStudyPreferences(),
    );
    addTearDown(() {
      controller.dispose();
      fixture.close();
    });
    await controller.open(dictionaryContext(strongs: <String>['G3056']));
    final Future<void> old = controller.openEntry('G4487');
    await repository.entryStarted.future;
    controller.close();
    repository.entryPending.complete(
      await fixture.repository.entry('strongsgreek', 'G4487'),
    );
    await old;
    expect(controller.entry!.id, 'G3056');
    expect(controller.isLoading, isFalse);
    expect(controller.historyLength, 0);
  });

  test('a missing linked word cancels an older entry interaction', () async {
    final DictionaryFixture fixture = DictionaryFixture();
    final DelayedDictionaryRepository repository = DelayedDictionaryRepository(
      fixture.repository,
    )..delayEntry = 'G4487';
    final DictionaryController controller = DictionaryController(
      repository: repository,
      preferences: MemoryStudyPreferences(),
    );
    addTearDown(() {
      controller.dispose();
      fixture.close();
    });
    await controller.open(dictionaryContext(strongs: <String>['G3056']));
    final Future<void> old = controller.openEntry('G4487');
    await repository.entryStarted.future;
    await controller.openEntry('missing');
    repository.entryPending.complete(
      await fixture.repository.entry('strongsgreek', 'G4487'),
    );
    await old;
    expect(controller.entry!.id, 'G3056');
    expect(controller.isLoading, isFalse);
    expect(
      controller.error.toString(),
      contains('not in the dictionary index'),
    );
  });
}

Future<void> _waitForEntry(DictionaryController controller, String id) async {
  for (
    var attempt = 0;
    attempt < 100 && controller.entry?.id != id;
    attempt++
  ) {
    await Future<void>.delayed(Duration.zero);
  }
  expect(controller.entry?.id, id);
}

final class _ControlledDictionaryRepository implements DictionaryRepository {
  _ControlledDictionaryRepository(this.delegate);
  final DictionaryRepository delegate;
  Future<void> Function(String kind, String module, String? id, int count)?
  before;
  final Map<String, int> _counts = {};
  Future<void> _read(String kind, String module, [String? id]) async {
    final key = '$kind/$module/$id';
    final count = _counts.update(key, (value) => value + 1, ifAbsent: () => 1);
    await before?.call(kind, module, id, count);
  }

  @override
  Future<DictionaryCatalogue> catalogue({RequestCancellation? cancellation}) =>
      delegate.catalogue(cancellation: cancellation);
  @override
  Future<DictionaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    await _read('metadata', module);
    return delegate.metadata(module, cancellation: cancellation);
  }

  @override
  Future<DictionaryIndex> index(
    String module, {
    RequestCancellation? cancellation,
  }) async {
    await _read('index', module);
    return delegate.index(module, cancellation: cancellation);
  }

  @override
  Future<DictionaryEntry> entry(
    String module,
    String id, {
    RequestCancellation? cancellation,
  }) async {
    await _read('entry', module, id);
    return delegate.entry(module, id, cancellation: cancellation);
  }
}

final class DelayedDictionaryRepository
    implements DictionaryRepository, InstalledStudyResource {
  DelayedDictionaryRepository(this.delegate);
  bool installed = false;
  final Set<String> installedIds = {};
  Completer<bool>? statusPending;
  @override
  Future<bool> isInstalled(String id) =>
      statusPending?.future ??
      Future.value(installed || installedIds.contains(id));
  final DictionaryRepository delegate;
  String? delayModule;
  String? delayEntry;
  final Completer<void> entryStarted = Completer<void>();
  final Completer<DictionaryEntry> entryPending = Completer<DictionaryEntry>();
  final Completer<void> started = Completer<void>();
  final Completer<DictionaryIndex> pending = Completer<DictionaryIndex>();
  @override
  Future<DictionaryCatalogue> catalogue({RequestCancellation? cancellation}) =>
      delegate.catalogue(cancellation: cancellation);
  @override
  Future<DictionaryMetadata> metadata(
    String module, {
    RequestCancellation? cancellation,
  }) => delegate.metadata(module, cancellation: cancellation);
  @override
  Future<DictionaryIndex> index(
    String module, {
    RequestCancellation? cancellation,
  }) {
    if (module == delayModule) {
      started.complete();
      return pending.future;
    }
    return delegate.index(module, cancellation: cancellation);
  }

  @override
  Future<DictionaryEntry> entry(
    String module,
    String id, {
    RequestCancellation? cancellation,
  }) {
    if (id == delayEntry) {
      entryStarted.complete();
      return entryPending.future;
    }
    return delegate.entry(module, id, cancellation: cancellation);
  }
}

StudyContext _browserContext() {
  final source = dictionaryContext();
  return StudyContext(
    passage: source.passage,
    bookName: source.bookName,
    language: source.language,
    verse: source.verse,
  );
}
