import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:getbible/application/app_state.dart';
import 'package:getbible/data/api/getbible_api_client.dart';
import 'package:getbible/data/database/local_database.dart';
import 'package:getbible/data/repositories/sql_notebook_repository.dart';
import 'package:getbible/domain/models/notebook.dart';
import 'package:getbible/domain/models/offline_resource.dart';
import 'package:getbible/domain/models/passage.dart';
import 'package:getbible/domain/repositories/notebook_repository.dart';
import 'package:getbible/main.dart';
import 'package:getbible/presentation/widgets/reader_translation_field.dart';
import 'package:getbible/presentation/widgets/study_workspace.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:provider/provider.dart';

import 'support/study_api_fixture.dart';

void main() {
  testWidgets(
    'Back waits for a confirmed import and returning reopens visible Study',
    (tester) async {
      _wideReader(tester);
      final fixture = StudyApiFixture();
      late _DelayedNotebookRepository repository;
      final state = (await tester.runAsync(() async {
        final database = await LocalDatabase.memory();
        repository = _DelayedNotebookRepository(
          SqlNotebookRepository(database),
        );
        final state = AppState.fromDatabase(
          database,
          api: fixture.reader.api,
          notebookRepository: repository,
        );
        await state.loadPassage(
          const Passage(translation: 'tst', book: 1, chapter: 1, verse: 1),
        );
        await state.study.notebooks.createNotebook(title: 'Local notebook');
        await state.saveVerseNote(1, 'Genesis 1:1', 'Imported private note');
        final backup = await state.portability.exportComplete();
        expect(backup, isNotNull);
        await state.deleteVerseNote(1);
        await state.portability.prepareImport(backup!);
        expect(state.portability.preparedImport, isNotNull);
        return state;
      }))!;
      addTearDown(() async {
        repository.release();
        await tester.runAsync(state.close);
      });
      await _mount(tester, state);
      await tester.tap(find.text(state.ui('study')));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<StudyTab>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Commentary').last);
      await _settle(tester);
      expect(state.study.commentary.chapter, isNotNull);
      expect(state.study.commentary.selectedModule!.id, 'fixture');

      await _openDrawerItem(tester, state, 'Backup and restore');
      repository.holdNextSave();
      state.study.notebooks.updateBlockText(
        state.study.notebooks.notebook!.blocks.first.id,
        'A draft that import must save before merging',
      );
      await tester.ensureVisible(find.text('Confirm import'));
      await tester.tap(find.text('Confirm import'));
      await tester.runAsync(
        () => repository.started.future.timeout(const Duration(seconds: 5)),
      );
      await tester.pump();
      expect(state.portability.busy, isTrue);
      expect(find.byTooltip('Back'), findsNothing);

      // Exercise the system Back path as well as the visible app-bar affordance.
      // The underlying reader must remain inaccessible until merge + refresh.
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.text('Backup and restore'), findsOneWidget);
      expect(state.portability.importResult, isNull);
      await tester.runAsync(() async {
        repository.release();
        await _until(() => !state.portability.busy);
      });
      await tester.pumpAndSettle();
      expect(state.portability.error, isNull);
      expect(state.portability.importResult, isNotNull);
      expect(state.notes.single.text, 'Imported private note');
      expect(find.byTooltip('Back'), findsOneWidget);
      await tester.tap(find.byTooltip('Back'));
      await _settle(tester);
      expect(find.text('Backup and restore'), findsNothing);
      // Study is now a modal surface at desktop sizes too. Reopen it through
      // the launcher after returning from the independently owned import page.
      await tester.tap(find.text(state.ui('study')));
      await _settle(tester);
      await tester.tap(find.byType(DropdownButtonFormField<StudyTab>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Commentary').last);
      await _settle(tester);
      expect(state.study.commentary.context, isNotNull);
      expect(state.study.commentary.selectedModule!.id, 'fixture');
      expect(state.study.commentary.chapter, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _closeWithPumps(tester, state);
    },
  );

  testWidgets(
    'a Bible installed after Setup closes appears in reader choices automatically',
    (tester) async {
      _wideReader(tester);
      final fixture = _DelayedBibleFixture();
      final state = (await tester.runAsync(() async {
        final state = AppState.fromDatabase(
          await LocalDatabase.memory(),
          api: fixture.api,
        );
        await state.offline.discover();
        final initial = state.offline.catalog.singleWhere(
          (item) => item.kind == OfflineResourceKind.bible && item.id == 'fx',
        );
        await state.offline.install(initial);
        expect(state.offline.error, isNull);
        await state.loadPassage(
          const Passage(
            translation: 'fx',
            book: 900000123,
            chapter: 3,
            verse: 7,
          ),
        );
        expect(state.error, isNull);
        return state;
      }))!;
      addTearDown(() async {
        fixture.release();
        await tester.runAsync(state.close);
      });
      final originalChapter = state.current;
      final originalPassage = state.passage;
      expect(state.translations.map((item) => item.abbreviation), ['fx']);
      await _mount(tester, state);
      await _openDrawerItem(tester, state, 'Downloads & storage');
      late Future<void> installation;
      await tester.runAsync(() async {
        final next = state.offline.catalog.singleWhere(
          (item) => item.kind == OfflineResourceKind.bible && item.id == 'fy',
        );
        installation = state.offline.install(next);
      });
      await _pumpUntil(tester, () => fixture.started.isCompleted);
      await tester.pump();
      expect(state.offline.installing, isTrue);
      await tester.tap(find.byTooltip('Close offline resources'));
      await _settle(tester);
      expect(find.text('Downloads & storage'), findsNothing);
      expect(state.translations.map((item) => item.abbreviation), ['fx']);

      await tester.runAsync(() async {
        fixture.release();
        await installation;
        expect(state.offline.error, isNull);
      });
      await _pumpUntil(
        tester,
        () => state.translations.any((item) => item.abbreviation == 'fy'),
      );
      await tester.pumpAndSettle();
      expect(state.current, same(originalChapter));
      expect(state.passage, originalPassage);
      await tester.tap(find.byTooltip(state.ui('openBibleNavigation')));
      await tester.pumpAndSettle();
      final field = tester.widget<ReaderTranslationField>(
        find.byType(ReaderTranslationField),
      );
      expect(
        field.translations.map((item) => item.abbreviation),
        contains('fy'),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await _closeWithPumps(tester, state);
    },
  );
}

void _wideReader(WidgetTester tester) {
  tester.view.physicalSize = const Size(1250, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _mount(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    ChangeNotifierProvider.value(value: state, child: const GetBibleApp()),
  );
  await tester.pumpAndSettle();
}

Future<void> _openDrawerItem(
  WidgetTester tester,
  AppState state,
  String label,
) async {
  if (find.byType(StudyWorkspace).evaluate().isNotEmpty) {
    await tester.tap(find.byTooltip('Close Study tools'));
    await _settle(tester);
  }
  await tester.tap(find.byTooltip(state.ui('openBibleNavigation')));
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text(label));
  await tester.tap(find.text(label));
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 50)),
  );
  await tester.pumpAndSettle();
}

Future<void> _until(bool Function() ready) async {
  final deadline = DateTime.now().add(const Duration(seconds: 5));
  while (!ready()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('The expected completion was not observed within five seconds.');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

/// Widget initState owns some SQLite continuations in the fake-async zone.
/// Pump those frames while allowing real database and worker I/O to advance.
Future<void> _pumpUntil(WidgetTester tester, bool Function() ready) async {
  final watch = Stopwatch()..start();
  while (!ready()) {
    if (watch.elapsed > const Duration(seconds: 5)) {
      fail('The expected UI operation did not reach its controlled milestone.');
    }
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
}

/// Automatic public work starts in the widget binding's scheduling zone. Keep
/// pumping while shutdown cancels it and drains SQLite before leaving that zone.
Future<void> _closeWithPumps(WidgetTester tester, AppState state) async {
  var complete = false;
  late Future<void> closing;
  await tester.runAsync(() async {
    closing = state.close().whenComplete(() => complete = true);
  });
  await _pumpUntil(tester, () => complete);
  await tester.runAsync(() => closing);
}

/// Hold only the private save used by beforeSnapshot. Everything still reaches
/// the real SQLite notebook repository, including revision conflict handling.
final class _DelayedNotebookRepository implements NotebookRepository {
  _DelayedNotebookRepository(this.delegate);
  final NotebookRepository delegate;
  Completer<void>? _gate;
  Completer<void> started = Completer<void>();

  void holdNextSave() => _gate = Completer<void>();
  void release() {
    if (_gate?.isCompleted == false) _gate!.complete();
  }

  @override
  Future<void> save(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  }) async {
    final gate = _gate;
    if (gate != null && !gate.isCompleted) {
      if (!started.isCompleted) started.complete();
      await gate.future;
    }
    await delegate.save(
      notebook,
      expectedRevision: expectedRevision,
      editorId: editorId,
    );
  }

  @override
  Future<void> saveDraft(
    Notebook notebook, {
    required int? expectedRevision,
    String editorId = 'primary',
  }) => delegate.saveDraft(
    notebook,
    expectedRevision: expectedRevision,
    editorId: editorId,
  );
  @override
  Future<List<NotebookSummary>> notebooks() => delegate.notebooks();
  @override
  Future<Notebook?> notebook(String id) => delegate.notebook(id);
  @override
  Future<List<NotebookDraft>> drafts() => delegate.drafts();
  @override
  Future<void> discardDraft(
    String id,
    int revision, {
    String editorId = 'primary',
  }) => delegate.discardDraft(id, revision, editorId: editorId);
  @override
  Future<void> delete(String id) => delegate.delete(id);
  @override
  Future<String?> selectedNotebook() => delegate.selectedNotebook();
  @override
  Future<void> selectNotebook(String? id) => delegate.selectNotebook(id);
}

final class _DelayedBibleFixture {
  _DelayedBibleFixture() {
    final source = File(
      'test/fixtures/bible_v3/rich_translation.json',
    ).readAsStringSync();
    final second = Map<String, Object?>.from(jsonDecode(source) as Map)
      ..['abbreviation'] = 'fy'
      ..['translation'] = 'Second installed Bible';
    documents = {
      'fx': utf8.encode(source),
      'fy': utf8.encode(jsonEncode(second)),
    };
    api = GetBibleApiClient(client: MockClient(_respond));
  }

  late final Map<String, List<int>> documents;
  late final GetBibleApiClient api;
  final started = Completer<void>();
  final _gate = Completer<void>();
  void release() {
    if (!_gate.isCompleted) _gate.complete();
  }

  Future<http.Response> _respond(http.Request request) async {
    if (request.url.host != 'api.getbible.net') {
      return http.Response('No Study resource in this fixture', 404);
    }
    if (request.url.path == '/v3/translations.json') {
      return http.Response(
        jsonEncode({
          for (final entry in documents.entries)
            entry.key: {
              ...(Map<String, Object?>.from(
                jsonDecode(utf8.decode(entry.value)) as Map,
              )..remove('books')),
              'sha': sha1.convert(entry.value).toString(),
            },
        }),
        200,
      );
    }
    for (final entry in documents.entries) {
      if (request.url.path == '/v3/${entry.key}.sha') {
        return http.Response(sha1.convert(entry.value).toString(), 200);
      }
      if (request.url.path == '/v3/${entry.key}.json') {
        if (entry.key == 'fy') {
          if (!started.isCompleted) started.complete();
          await _gate.future;
        }
        return http.Response.bytes(entry.value, 200);
      }
    }
    return http.Response('Missing fixture resource', 404);
  }
}
