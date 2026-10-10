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
