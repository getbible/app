import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/offline_controller.dart';
import 'package:getbible/core/request_cancellation.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/domain/models/offline_resource.dart';
import 'package:getbible/domain/repositories/offline_resource_repository.dart';

void main() {
  late LocalDatabase database;
  late SqlOfflineResourceStore store;
  late SqlOfflineFreshnessStore freshness;
  late DateTime now;
  final controllers = <OfflineController>[];

  setUp(() async {
    now = DateTime.utc(2026, 1, 1);
    database = await LocalDatabase.memory();
    store = SqlOfflineResourceStore(database, clock: () => now);
    freshness = SqlOfflineFreshnessStore(database);
  });
  tearDown(() async {
    for (final controller in controllers) {
      await controller.close();
      controller.dispose();
    }
    controllers.clear();
    await database.close();
  });

  OfflineController create(
    List<_Installer> installers, {
    Future<void> Function()? clearPublicCaches,
  }) {
    final controller = OfflineController(
      store: store,
      freshness: freshness,
      installers: installers,
      clock: () => now,
      clearPublicCaches: clearPublicCaches,
    );
    controllers.add(controller);
    return controller;
  }

  test(
    'first use is deduplicated and all complete downloads run sequentially',
    () async {
      final installer = _Installer(OfflineResourceKind.bible, [
        'first',
        'second',
      ]);
      final started = Completer<void>();
      final release = Completer<void>();
      var active = 0;
      var maximumActive = 0;
      installer.onInstall = (resource, cancellation) async {
        active++;
        if (active > maximumActive) maximumActive = active;
        if (resource.id == 'first') {
          started.complete();
          await cancellation.bind(release.future);
        }
        active--;
      };
      final controller = create([installer]);
      final first = controller.ensureAvailable(
        OfflineResourceKind.bible,
        'first',
      );
      await started.future;
      final duplicate = controller.ensureAvailable(
        OfflineResourceKind.bible,
        'first',
      );
      final second = controller.ensureAvailable(
        OfflineResourceKind.bible,
        'second',
      );
      await Future<void>.delayed(Duration.zero);
      expect(controller.queuedCount, 1);
      release.complete();
      await Future.wait([first, duplicate, second]);
      expect(installer.installs, ['first', 'second']);
      expect(installer.resolves, ['first', 'second']);
      expect(maximumActive, 1);
      expect(controller.installed, hasLength(2));
    },
  );

  test(
    'foreground Bible follows the active module before remaining automatic downloads',
    () async {
      final dictionaries = _Installer(OfflineResourceKind.dictionary, [
        'one',
        'two',
        'three',
      ]);
      final bible = _Installer(OfflineResourceKind.bible, ['selected']);
      final order = <String>[];
      final started = Completer<void>();
      final release = Completer<void>();
      dictionaries.onInstall = (resource, cancellation) async {
        order.add(resource.id);
        if (resource.id == 'one') {
          started.complete();
          await cancellation.bind(release.future);
        }
      };
      bible.onInstall = (resource, _) async {
        order.add(resource.id);
      };
      final controller = create([dictionaries, bible]);
      await controller.initialize();
      await started.future;
      expect(controller.queuedCount, 2);
      final opened = controller.ensureAvailable(bible.kind, 'selected');
      await Future<void>.delayed(Duration.zero);
      expect(
        order,
        ['one'],
        reason: 'Priority must not cancel the active verified installation.',
      );
      release.complete();
      await opened;
      await _idle(controller);
      expect(order, ['one', 'selected', 'two', 'three']);
    },
  );

  test(
    'opening an already queued module promotes its existing job without duplication',
    () async {
      final dictionaries = _Installer(OfflineResourceKind.dictionary, [
        'one',
        'two',
        'three',
      ]);
      final started = Completer<void>();
      final release = Completer<void>();
      dictionaries.onInstall = (resource, cancellation) async {
        if (resource.id == 'one') {
          started.complete();
          await cancellation.bind(release.future);
        }
      };
      final controller = create([dictionaries]);
      await controller.initialize();
      await started.future;
      final opened = controller.ensureAvailable(dictionaries.kind, 'three');
      await Future<void>.delayed(Duration.zero);
      release.complete();
      await opened;
      await _idle(controller);
      expect(dictionaries.installs, ['one', 'three', 'two']);
      expect(dictionaries.resolves, ['one', 'three', 'two']);
    },
  );

  test(
    'a full automatic queue admits the current Bible and later completes the deferred module',
    () async {
      final dictionaries = _Installer(
        OfflineResourceKind.dictionary,
        List.generate(
          OfflineController.maximumQueuedResources,
          (index) => 'dictionary-$index',
        ),
      );
      final bible = _Installer(OfflineResourceKind.bible, ['selected']);
      final started = Completer<void>();
      final release = Completer<void>();
      final order = <String>[];
      dictionaries.onInstall = (resource, cancellation) async {
        order.add(resource.id);
        if (resource.id == 'dictionary-0') {
          started.complete();
          await cancellation.bind(release.future);
        }
      };
      bible.onInstall = (resource, _) async {
        order.add(resource.id);
      };
      final controller = create([dictionaries, bible]);
      await controller.initialize();
      await started.future;
      expect(
        controller.queuedCount,
        OfflineController.maximumQueuedResources - 1,
      );
      final opened = controller.ensureAvailable(bible.kind, 'selected');
      await Future<void>.delayed(Duration.zero);
      expect(controller.queuedCount, OfflineController.maximumQueuedResources);
      release.complete();
      await opened;
      expect(order.take(2), ['dictionary-0', 'selected']);
      await _idle(controller);
      expect(
        dictionaries.installs,
        hasLength(OfflineController.maximumQueuedResources),
      );
      expect(dictionaries.installs.toSet(), dictionaries.ids.toSet());
      expect(controller.failures, isEmpty);
    },
  );

  test(
    'successful checks persist across restart; monthly unchanged hash avoids bulk',
    () async {
      final installer = _Installer(OfflineResourceKind.bible, ['test']);
      final first = create([installer]);
      await first.ensureAvailable(OfflineResourceKind.bible, 'test');
      final generation = first.installed.single.generation;
      await first.close();
      now = now.add(const Duration(days: 29));
      final reopened = create([installer]);
      await reopened.ensureAvailable(OfflineResourceKind.bible, 'test');
      expect(installer.checks, isEmpty);
      now = now.add(const Duration(days: 1));
      await reopened.ensureAvailable(OfflineResourceKind.bible, 'test');
      expect(installer.checks, ['test']);
      expect(installer.installs, ['test']);
      expect(
        (await freshness.read(installer.resource('test').key))!.checkedAt,
        now,
      );
      installer.revision = 'two';
      await reopened.checkForUpdates(force: true);
      await _idle(reopened);
      expect(installer.checks, ['test', 'test']);
      expect(installer.installs, ['test', 'test']);
      expect(reopened.installed.single.resource.revision, 'two');
      expect(reopened.installed.single.generation, isNot(generation));
    },
  );

  test(
    'failed checks retain success date and persist bounded exponential retry',
    () async {
      final installer = _Installer(OfflineResourceKind.bible, ['test']);
      final controller = create([installer]);
      await controller.ensureAvailable(OfflineResourceKind.bible, 'test');
      final key = installer.resource('test').key;
      final successful = (await freshness.read(key))!.checkedAt;
      now = now.add(const Duration(days: 30));
      installer.failProbe = true;
      await controller.ensureAvailable(OfflineResourceKind.bible, 'test');
      var status = (await freshness.read(key))!;
      expect(status.checkedAt, successful);
      expect(status.retryAfter, now.add(const Duration(minutes: 15)));
      await controller.ensureAvailable(OfflineResourceKind.bible, 'test');
      expect(installer.checks, hasLength(1));
      for (var attempt = 0; attempt < 9; attempt++) {
        now = status.retryAfter!;
        await controller.ensureAvailable(OfflineResourceKind.bible, 'test');
        status = (await freshness.read(key))!;
        expect(status.checkedAt, successful);
        expect(
          status.retryAfter!.difference(now),
          lessThanOrEqualTo(const Duration(days: 1)),
        );
      }
      expect(status.retryAfter!.difference(now), const Duration(days: 1));
      installer.failProbe = false;
      await controller.checkForUpdates(force: true);
      await _idle(controller);
      status = (await freshness.read(key))!;
      expect(status.checkedAt, now);
      expect(status.retryAfter, isNull);
      expect(controller.failures, isEmpty);
      expect(installer.installs, hasLength(1));
    },
  );

  test(
    'all Study catalogues prepare by default; bookmarks and unrelated Bibles do not',
    () async {
      final dictionaries = _Installer(OfflineResourceKind.dictionary, [
        'one',
        'two',
      ]);
      final commentaries = _Installer(OfflineResourceKind.commentary, [
        'notes',
      ]);
      final bookmarks = _Installer(OfflineResourceKind.bookmarks, ['all']);
      final bible = _Installer(OfflineResourceKind.bible, [
        'selected',
        'other',
      ]);
      final controller = create([bible, dictionaries, commentaries, bookmarks]);
      await controller.initialize();
      await _idle(controller);
      expect(dictionaries.installs, ['one', 'two']);
      expect(commentaries.installs, ['notes']);
      expect(bible.discoveries, 0);
      expect(bible.installs, isEmpty);
      expect(bookmarks.discoveries, 0);
      expect(bookmarks.installs, isEmpty);
      expect(
        controller.catalog.map((r) => r.id),
        containsAll(['one', 'two', 'notes']),
      );
      await controller.ensureAvailable(OfflineResourceKind.bookmarks, 'all');
      expect(bookmarks.installs, isEmpty);
    },
  );

  test(
    'saved plans resume unfinished modules without premature catalogue recheck',
    () async {
      final installer = _Installer(OfflineResourceKind.dictionary, [
        'one',
        'two',
      ]);
      final resources = installer.ids.map(installer.resource).toList();
      await freshness.saveAutomaticResources(
        installer.kind,
        installer.sourceUri,
        resources,
      );
      await freshness.recordCatalogueSuccess(
        'catalogue|${installer.sourceUri}|${installer.kind.name}',
        now,
      );
      await freshness.setExcluded(resources.first.key, true);
      final controller = create([installer]);
      await controller.initialize();
      await _idle(controller);
      expect(installer.discoveries, 0);
      expect(installer.installs, ['two']);
      expect(controller.excludedKeys, contains(resources.first.key));
      await controller.ensureAvailable(installer.kind, 'one');
      expect(installer.installs, ['two']);
      await controller.setAutomaticDownload(resources.first, true);
      await _idle(controller);
      expect(installer.installs, ['two', 'one']);
    },
  );

  test(
    'clear cancels active and queued jobs, preserves private data, and waits for later use',
    () async {
      final installer = _Installer(OfflineResourceKind.bible, ['one', 'two']);
      final started = Completer<void>();
      installer.onInstall = (resource, cancellation) async {
        started.complete();
        await cancellation.bind(Completer<void>().future);
      };
      await database.writeSetting('private-note', {'text': 'keep me'});
      var cacheClears = 0;
      final controller = create(
        [installer],
        clearPublicCaches: () async {
          cacheClears++;
        },
      );
      final one = controller.ensureAvailable(installer.kind, 'one');
      await started.future;
      final two = controller.ensureAvailable(installer.kind, 'two');
      await Future<void>.delayed(Duration.zero);
      await controller.clearDownloads();
      await Future.wait([one, two]);
      expect(controller.installed, isEmpty);
      expect(controller.attempts, isEmpty);
      expect(controller.busy, isFalse);
      expect(installer.installs, ['one']);
      expect(cacheClears, 1);
      expect(await database.readSetting('private-note'), contains('keep me'));
      installer.onInstall = null;
      await controller.ensureAvailable(installer.kind, 'one');
      await _idle(controller);
      expect(controller.installed.single.resource.id, 'one');
    },
  );

  test(
    'remove cancels only its own work and explicit bookmarks stay removed',
    () async {
      final bible = _Installer(OfflineResourceKind.bible, ['one', 'two']);
      final bookmarks = _Installer(OfflineResourceKind.bookmarks, ['all']);
      final started = Completer<void>();
      bible.onInstall = (resource, cancellation) async {
        if (resource.id == 'one') {
          started.complete();
          await cancellation.bind(Completer<void>().future);
        }
      };
      final controller = create([bible, bookmarks]);
      final one = controller.ensureAvailable(bible.kind, 'one');
      await started.future;
      final two = controller.ensureAvailable(bible.kind, 'two');
      await controller.remove(bible.resource('one').key);
      await Future.wait([one, two]);
      expect(controller.installed.single.resource.id, 'two');
      await controller.install(bookmarks.resource('all'));
      await controller.remove(bookmarks.resource('all').key);
      await controller.checkForUpdates(force: true);
      await _idle(controller);
      expect(bookmarks.installs, ['all']);
      expect(
        controller.installed.where((r) => r.resource.kind == bookmarks.kind),
        isEmpty,
      );
    },
  );

  test(
    'rapid toggles and clear retain final persistent exclusions and no stale activation',
    () async {
      final installer = _Installer(OfflineResourceKind.dictionary, [
        'one',
        'two',
      ]);
      final controller = create([installer]);
      await controller.ensureAvailable(installer.kind, 'one');
      final one = installer.resource('one');
      final off = controller.setAutomaticDownload(one, false);
      final on = controller.setAutomaticDownload(one, true);
      final offAgain = controller.setAutomaticDownload(one, false);
      final clear = controller.clearDownloads();
      final excludeSecond = controller.setAutomaticDownload(
        installer.resource('two'),
        false,
      );
      await Future.wait([off, on, offAgain, clear, excludeSecond]);
      await _idle(controller);
      expect(controller.installed, isEmpty);
      expect(await freshness.readExcludedKeys(), {
        one.key,
        installer.resource('two').key,
      });
      await controller.ensureAvailable(installer.kind, 'one');
      await _idle(controller);
      expect(controller.installed, isEmpty);
      expect(controller.excludedKeys, contains(one.key));
    },
  );

  test(
    'clear invalidates already-running foreground callbacks before awaiting deletion',
    () async {
      final installer = _Installer(OfflineResourceKind.bible, ['one']);
      final controller = create([installer]);
      final captured = controller.contentEpoch;
      final clearing = controller.clearDownloads();
      expect(controller.contentEpoch, isNot(captured));
      await controller.ensureAvailable(
        installer.kind,
        'one',
        expectedEpoch: captured,
      );
      await clearing;
      await controller.ensureAvailable(
        installer.kind,
        'one',
        expectedEpoch: captured,
      );
      expect(installer.installs, isEmpty);
      await controller.ensureAvailable(
        installer.kind,
        'one',
        expectedEpoch: controller.contentEpoch,
      );
      expect(installer.installs, ['one']);
    },
  );

  test(
    'temporary removal suppresses a late catalogue until a new resource use',
    () async {
      final installer = _Installer(OfflineResourceKind.dictionary, ['one']);
      final discovered = Completer<void>();
      final release = Completer<void>();
      installer.onDiscover = (cancellation) async {
        discovered.complete();
        await cancellation.bind(release.future);
      };
      final controller = create([installer]);
      await controller.initialize();
      await discovered.future;
      await controller.remove(installer.resource('one').key);
      release.complete();
      await _idle(controller);
      expect(installer.installs, isEmpty);
      await controller.ensureAvailable(installer.kind, 'one');
      expect(installer.installs, ['one']);
    },
  );

  test(
    'one module failure remains visible while unrelated resources finish',
    () async {
      final broken = _Installer(OfflineResourceKind.dictionary, ['bad'])
        ..failProbe = true;
      final healthy = _Installer(OfflineResourceKind.commentary, ['good']);
      final controller = create([broken, healthy]);
      await controller.initialize();
      await _idle(controller);
      final failedKey = broken.resource('bad').key;
      expect(controller.failures[failedKey], contains('Network unavailable'));
      expect(controller.error, contains('Network unavailable'));
      expect(controller.installed.single.resource.id, 'good');
      final status = (await freshness.read(failedKey))!;
      expect(status.checkedAt, isNull);
      expect(status.retryAfter, now.add(OfflineController.initialRetryDelay));
      await controller.ensureAvailable(broken.kind, 'bad');
      expect(broken.resolves, ['bad']);
    },
  );

  test(
    'shutdown drains queued work and later resume can retry safely',
    () async {
      final installer = _Installer(OfflineResourceKind.bible, ['one', 'two']);
      final started = Completer<void>();
      installer.onInstall = (resource, cancellation) async {
        started.complete();
        await cancellation.bind(Completer<void>().future);
      };
      final controller = create([installer]);
      final one = controller.ensureAvailable(installer.kind, 'one');
      await started.future;
      final two = controller.ensureAvailable(installer.kind, 'two');
      await controller.close();
      await Future.wait([one, two]);
      expect(controller.installed, isEmpty);
      expect(controller.queuedCount, 0);
      expect(installer.installs, ['one']);
      controller.resume();
      installer.onInstall = null;
      await controller.install(installer.resource('one'));
      expect(controller.installed.single.resource.id, 'one');
    },
  );
}

Future<void> _idle(OfflineController controller) async {
  // Work is driven by observable controller state, not an assumed timing delay.
  while (controller.busy) {
    await Future<void>.delayed(Duration.zero);
  }
}

final class _Installer implements OfflineResourceInstaller {
  _Installer(this.kind, this.ids);
  final OfflineResourceKind kind;
  final List<String> ids;
  String revision = 'one';
  bool failProbe = false;
  int discoveries = 0;
  final List<String> resolves = [];
  final List<String> checks = [];
  final List<String> installs = [];
  Future<void> Function(OfflineResourceDescriptor, RequestCancellation)?
  onInstall;
  Future<void> Function(RequestCancellation)? onDiscover;
  @override
  Uri get sourceUri => Uri.parse('https://example.test/${kind.name}/v1');
  @override
  Set<OfflineResourceKind> get supportedKinds => {kind};
  OfflineResourceDescriptor resource(String id) => OfflineResourceDescriptor(
    kind: kind,
    id: id,
    title: id,
    sourceUri: sourceUri,
    revision: revision,
  );
  @override
  Future<List<OfflineResourceDescriptor>> discover(
    RequestCancellation cancellation,
  ) async {
    discoveries++;
    await onDiscover?.call(cancellation);
    cancellation.throwIfCancelled();
    return ids.map(resource).toList();
  }

  @override
  Future<OfflineResourceDescriptor> resolve(
    OfflineResourceKind kind,
    String id,
    RequestCancellation cancellation,
  ) async {
    resolves.add(id);
    cancellation.throwIfCancelled();
    if (failProbe) throw const OfflineStorageException('Network unavailable');
    return resource(id);
  }

  @override
  Future<OfflineResourceDescriptor> checkRevision(
    OfflineResourceDescriptor value,
    RequestCancellation cancellation,
  ) async {
    checks.add(value.id);
    cancellation.throwIfCancelled();
    if (failProbe) throw const OfflineStorageException('Network unavailable');
    return resource(value.id);
  }

  @override
  Future<void> install(
    OfflineResourceDescriptor value,
    OfflineInstallSink sink,
    RequestCancellation cancellation,
  ) async {
    installs.add(value.id);
    await sink.writeDocument('content', '{"revision":"${value.revision}"}');
    await onInstall?.call(value, cancellation);
    cancellation.throwIfCancelled();
  }
}
