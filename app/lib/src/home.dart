// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';

import 'app_commands.dart';
import 'app_settings.dart';
import 'binder_cover.dart';
import 'notebook.dart';
import 'page_title_field.dart';
import 'page_tree_view.dart';
import 'settings_menu.dart';

/// Sidebar with the page tree, and the open page's canvas.
class Home extends StatefulWidget {
  const Home({super.key, required this.notebook, this.settings});

  final Notebook notebook;

  /// This device's settings; the settings menu is shown when given.
  final AppSettings? settings;

  @override
  State<Home> createState() => _HomeState();
}

class _HomeState extends State<Home> {
  final _tree = GlobalKey<PageTreeViewState>();

  Notebook get notebook => widget.notebook;

  /// App-level shortcuts (Ctrl+N: new page). Keys bubble up from the canvas,
  /// a note editor or the title field to here; only the commands that work
  /// while editing answer, and the rest is left alone.
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    final actions = _tree.currentState;
    if (actions == null) return KeyEventResult.ignored;
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = HardwareKeyboard.instance;
    if (!k.isControlPressed && !k.isMetaPressed) return KeyEventResult.ignored;
    final command = pagesHeaderCommands(notebook, actions).resolve(event, editing: true);
    if (command == null) return KeyEventResult.ignored;
    command.run();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _onKey,
      child: Scaffold(body: _body()),
    );
  }

  Widget _body() {
    return ListenableBuilder(
      listenable: notebook,
      builder: (context, _) {
        final current = notebook.current;
        final m = NotedMetrics.of(context);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              width: m.sidebarWidth,
              child: ColoredBox(
                color: NotedColors.of(context).bgSidebar,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: PageTreeView(key: _tree, notebook: notebook)),
                    if (widget.settings != null)
                      SettingsMenu(settings: widget.settings!, notebook: notebook),
                  ],
                ),
              ),
            ),
            const VerticalDivider(width: 1),
            Expanded(
              child: notebook.cover != null
                  ? BinderCover(
                      key: ValueKey('cover-${notebook.coverPath}'),
                      notebook: notebook,
                      path: notebook.coverPath!,
                    )
                  : current == null
                  ? const Center(child: CircularProgressIndicator())
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: EdgeInsets.fromLTRB(m.space6, m.space4, m.space6, m.space2),
                          child: PageTitleField(
                            key: ValueKey('title-${current.page.id}'),
                            notebook: notebook,
                            pageId: current.page.id,
                          ),
                        ),
                        const Divider(height: 1),
                        if (notebook.readOnlyReason != null)
                          ReadOnlyBanner(
                            key: const ValueKey('read-only-banner'),
                            reason: notebook.readOnlyReason!,
                          ),
                        Expanded(
                          child: PageCanvas(
                            key: ValueKey(current.page.id),
                            controller: current,
                            tools: notebook.tools,
                            readOnly: notebook.readOnlyReason != null,
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }
}
