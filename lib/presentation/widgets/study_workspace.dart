import 'package:flutter/material.dart';

import 'package:flutter/services.dart';

import '../../core/ui_strings.dart';

import '../../domain/models/study_context.dart';

enum StudyTab {
  dictionary('Dictionary'),
  commentary('Commentary'),
  topics('Topics'),
  markings('My markings'),
  notes('Notebooks'),
  verseNotes('Verse notes');

  const StudyTab(this.label);
  final String label;
  String localizedLabel(BuildContext context) => switch (this) {
    dictionary => UiStrings.of(context).text('Dictionary'),
    commentary => UiStrings.of(context).text('Commentary'),
    topics => UiStrings.of(context).text('Topics'),
    markings => UiStrings.of(context).text('My markings'),
    notes => UiStrings.of(context).text('Notebooks'),
    verseNotes => UiStrings.of(context).text('Verse notes'),
  };
}

/// One adaptive surface, with resource loading owned by its selected panel.
/// Closing this widget never replaces or scrolls the reader beneath it.
class StudyWorkspace extends StatefulWidget {
  const StudyWorkspace({
    super.key,
    required this.context,
    required this.initialTab,
    required this.panelBuilder,
    required this.onClose,
    required this.onSearchSelection,
    this.onTabChanged,
    this.contextual = false,
  });

  final StudyContext context;
  final StudyTab initialTab;
  final Widget Function(BuildContext, StudyTab) panelBuilder;
  final VoidCallback onClose;
  final VoidCallback? onSearchSelection;
  final ValueChanged<StudyTab>? onTabChanged;

  /// Scripture study has two visible resource tabs. Personal tools keep their
  /// independent chooser, so opening a word never lands in bookmark management.
  final bool contextual;

  @override
  State<StudyWorkspace> createState() => _StudyWorkspaceState();
}

class _StudyWorkspaceState extends State<StudyWorkspace>
    with SingleTickerProviderStateMixin {
  late StudyTab _tab = widget.initialTab;
  late final TabController _tabs;
  final FocusNode _resourceFocus = FocusNode(
    debugLabel: 'Study resource chooser',
  );

  @override
  void initState() {
    super.initState();
    _tabs = TabController(
      length: 2,
      vsync: this,
      initialIndex: _tab == StudyTab.commentary ? 1 : 0,
    )..addListener(_onResourceTab);
  }

  @override
  void dispose() {
    _tabs.dispose();
    _resourceFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(StudyWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.context, oldWidget.context) ||
        widget.initialTab != oldWidget.initialTab) {
      _tab = widget.initialTab;
      _tabs.index = _tab == StudyTab.commentary ? 1 : 0;
    }
  }

  void _onResourceTab() {
    if (!widget.contextual) return;
    final next = _tabs.index == 0 ? StudyTab.dictionary : StudyTab.commentary;
    if (_tab == next) return;
    setState(() => _tab = next);
    widget.onTabChanged?.call(next);
  }

  Widget _selection(BuildContext context) => ColoredBox(
    color: Theme.of(context).colorScheme.surfaceContainerLow,
    child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final selected = SelectableText(
            widget.context.selectedText!,
            textDirection: widget.context.direction.toUpperCase() == 'RTL'
                ? TextDirection.rtl
                : TextDirection.ltr,
            style: Theme.of(context).textTheme.titleMedium,
          );
          final search = TextButton(
            onPressed: widget.onSearchSelection,
            child: Text(UiStrings.of(context).text('Search selection')),
          );
          return constraints.maxWidth < 420 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [selected, search],
                )
              : Row(
                  children: [
                    Expanded(child: selected),
                    const SizedBox(width: 16),
                    search,
                  ],
                );
        },
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => CallbackShortcuts(
    bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
    },
    child: FocusTraversalGroup(
      child: Focus(
        autofocus: true,
        child: Material(
          child: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  ConstrainedBox(
                    constraints: BoxConstraints(
                      maxHeight: constraints.maxHeight * .45,
                    ),
                    child: SingleChildScrollView(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          ListTile(
                            title: Semantics(
                              header: true,
                              child: Text(
                                UiStrings.of(context).text(
                                  widget.contextual
                                      ? 'Study Scripture'
                                      : 'Study tools',
                                ),
                              ),
                            ),
                            subtitle: Text(
                              widget.contextual
                                  ? '${widget.context.translation.toUpperCase()} · ${widget.context.label}'
                                  : widget.context.label,
                            ),
                            trailing: IconButton(
                              tooltip: UiStrings.of(
                                context,
                              ).text('Close Study tools'),
                              onPressed: widget.onClose,
                              icon: const Icon(Icons.close),
                            ),
                          ),
                          if (widget.contextual &&
                              widget.context.selectedText != null)
                            _selection(context),
                          if (widget.contextual)
                            TabBar(
                              controller: _tabs,
                              isScrollable: true,
                              tabAlignment: TabAlignment.start,
                              tabs: [
                                Tab(
                                  text: UiStrings.of(
                                    context,
                                  ).text('Dictionaries'),
                                ),
                                Tab(
                                  text: UiStrings.of(
                                    context,
                                  ).text('Commentaries'),
                                ),
                              ],
                            )
                          else
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: DropdownButtonFormField<StudyTab>(
                                initialValue: _tab,
                                focusNode: _resourceFocus,
                                itemHeight: null,
                                key: ValueKey<StudyTab>(_tab),
                                isExpanded: true,
                                decoration: InputDecoration(
                                  labelText: UiStrings.of(
                                    context,
                                  ).text('Study resource'),
                                ),
                                items: <DropdownMenuItem<StudyTab>>[
                                  for (final StudyTab tab in StudyTab.values)
                                    DropdownMenuItem<StudyTab>(
                                      value: tab,
                                      child: Text(
                                        UiStrings.of(context).text(tab.label),
                                      ),
                                    ),
                                ],
                                onChanged: (StudyTab? tab) {
                                  if (tab != null) {
                                    setState(() => _tab = tab);
                                    widget.onTabChanged?.call(tab);
                                  }
                                },
                              ),
                            ),
                          if (!widget.contextual &&
                              widget.onSearchSelection != null)
                            Padding(
                              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                              child: OutlinedButton.icon(
                                onPressed: widget.onSearchSelection,
                                icon: const Icon(Icons.search),
                                label: Text(
                                  UiStrings.of(
                                    context,
                                  ).text('Search selected text'),
                                ),
                              ),
                            ),
                          const Divider(),
                        ],
                      ),
                    ),
                  ),
                  Expanded(child: widget.panelBuilder(context, _tab)),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );
}
