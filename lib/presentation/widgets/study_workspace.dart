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
  });

  final StudyContext context;
  final StudyTab initialTab;
  final Widget Function(BuildContext, StudyTab) panelBuilder;
  final VoidCallback onClose;
  final VoidCallback? onSearchSelection;
  final ValueChanged<StudyTab>? onTabChanged;

  @override
  State<StudyWorkspace> createState() => _StudyWorkspaceState();
}

class _StudyWorkspaceState extends State<StudyWorkspace> {
  late StudyTab _tab = widget.initialTab;
  final FocusNode _resourceFocus = FocusNode(
    debugLabel: 'Study resource chooser',
  );

  @override
  void dispose() {
    _resourceFocus.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(StudyWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.context, oldWidget.context) ||
        widget.initialTab != oldWidget.initialTab) {
      _tab = widget.initialTab;
    }
  }

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
                                UiStrings.of(context).text('Study tools'),
                              ),
                            ),
                            subtitle: Text(widget.context.label),
                            trailing: IconButton(
                              tooltip: UiStrings.of(
                                context,
                              ).text('Close Study tools'),
                              onPressed: widget.onClose,
                              icon: const Icon(Icons.close),
                            ),
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                          if (widget.onSearchSelection != null)
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
