# Personal study and sermon notebooks

Study → Notes creates local titled notebooks with ordered text blocks and optional
Scripture references. Canonical verse notes remain the existing one-note-per-verse
inline workflow, visible across translations; a notebook never converts or
replaces them. Notebook and block IDs remain stable through edits and moves.

`Notebook` and `NotebookReference` are framework-independent validated contracts.
`NotebookRepository` separates persistence from `NotebookController`, and
`SqlNotebookRepository` delegates bounded operations to `LocalDatabase`.
`NotesPanel` contains native text editors, confirmation dialogs and typed reference
actions. It performs no SQL, HTTP or JSON parsing. Notebook lists load metadata;
the selected notebook's body is loaded on demand.

## Persistence and recovery

Schema 3 adds independent `notebooks`, `notebook_blocks` and `notebook_drafts`
tables. The forward schema 1/2 → 3 migration is transactional and leaves canonical
notes, note IDs/creation timestamps, marking groups/ranges, settings and saved
Scripture unchanged. Ordered block ranks are unique within a notebook. A save
activates its notebook metadata and all blocks in one transaction. A read captures
the parent and blocks in one transaction, preventing mixed document revisions.

Edits autosave after 300 ms of inactivity. Ctrl/⌘ + Enter saves immediately.
Closing the Notes widget and app suspension request a flush, and application
shutdown awaits the controller before closing SQLite. A forced process termination
before a pending debounce/write completes can lose that last uncommitted edit;
this is not a claim of keystroke-level crash durability.

An explicitly requested application close waits for the current draft revision
to be durable. If its journal cannot be written, close reports a storage failure
and keeps the editor and database available for retry. A draft whose journal is
durable may safely survive shutdown even if activation/conflict resolution is
pending; it is restored on restart. Older journaled revisions never count as
durability for a newer private edit.

Each edit first writes a durable draft journal. Activation failure retains the
entire draft and presents Retry. Selecting another notebook or explicitly opening
a Scripture citation preserves any failed draft. Restart restores the selected
notebook and journals without a network request. Independent editor identities
prevent one writer from clearing another writer's draft journal. A saved base
revision prevents a retained draft from overwriting newer local document edits.
Recovering a journal always forks a fresh editor identity; the original snapshot
remains immutable until successful activation or explicit copy, and cleanup
compares its exact captured revision. Edits to conflicted drafts still write
their own journals while document activation remains blocked.
Conflicting and additional recovered drafts can be explicitly saved as new
notebooks with new block IDs; both versions remain private and intact.

Documents are limited to 200 Unicode code points in the title, 1,000 blocks,
100,000 UTF-16 code units per text block/quotation, and 1,000,000 code units overall.
Source Scripture keeps its selected translation, original quotation, direction,
coordinate identity and attribution label. Inserting current Scripture previews
the captured context, optionally opens the shared Query preview, and requires
an explicit Insert. Public source updates never rewrite saved quotations.

Native editor input formatters enforce the same rune/UTF-16 and aggregate bounds
as the document model. An overflowing edit leaves the accepted text and caret
unchanged and displays a persistent actionable message. It never displays an
unpersisted rejected value as saved or truncates an existing suffix.

## Privacy and backup boundary

Notebook text is never sent to GetBible services. Reference preview sends only
the explicitly selected Scripture reference; opening a citation loads only that
passage. Canonical notes and notebooks remain separate private stores.

The current website-compatible v1/v2 backup contract includes canonical verse
notes and markings **but does not include notebooks**. The Notes surface states
this limitation. Notebook portability is roadmap step 12. Legacy reader-data
replacement/reset and Scripture/download cache deletion preserve notebook tables.
Notebook/block deletion requires an explicit confirmation in Notes.

## Verification

Run:

```bash
flutter test test/notebook_test.dart test/notes_panel_test.dart test/notebook_input_limit_test.dart test/bible_cache_migration_test.dart
```

Fixtures cover released schema 1 and 2, migration rollback, unchanged private
identities/timestamps, atomic activation failure and durable draft retention,
out-of-order saves, selection with failed drafts, offline recovery and conflicts.
Native widget tests cover compact RTL at 200% text, local editing, keyboard save,
exact quotation/reference insertion, passage navigation, reorder and confirmed
deletion. Real device suspension, screen-reader and store QA remain release gates.
