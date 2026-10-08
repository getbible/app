import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible_live/application/dictionary_controller.dart';
import 'package:getbible_live/core/request_cancellation.dart';
import 'package:getbible_live/domain/models/dictionary.dart';
import 'package:getbible_live/domain/models/service_envelopes.dart';
import 'package:getbible_live/domain/models/study_context.dart';
import 'package:getbible_live/domain/repositories/dictionary_repository.dart';

import 'support/dictionary_fixture.dart';

void main() {
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
    'missing language has explicit choice; remembered foreign choice is clearly retained',
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
      expect(controller.needsResourceChoice, isTrue);
      expect(controller.entry, isNull);
      expect(fixture.requests.length, 1);
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

final class DelayedDictionaryRepository implements DictionaryRepository {
  DelayedDictionaryRepository(this.delegate);
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
