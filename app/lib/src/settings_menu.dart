// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart'
    show Command, NotedMenuDivider, NotedMenuHeading, NotedMenuItem, NotedMetrics, ToolbarStyle;

import 'about_dialog.dart';
import 'app_commands.dart';
import 'app_settings.dart';
import 'microsoft_account.dart';
import 'notebook.dart';

/// The gear at the bottom of the sidebar: a menu to choose the theme, the
/// toolbar and the default folders for new pages and binders.
class SettingsMenu extends StatelessWidget {
  const SettingsMenu({super.key, required this.settings, this.notebook, this.microsoft});

  static const String _aboutId = 'about-noted';

  final AppSettings settings;

  /// The Microsoft account, in a build that has a client id; null hides every
  /// trace of Microsoft sign-in. Reached only through About Noted.
  final MicrosoftAccount? microsoft;

  /// Needed for the default folders; without it only the theme is offered.
  final Notebook? notebook;

  @override
  Widget build(BuildContext context) {
    final nb = notebook;
    final canPick = nb != null && nb.pickFolder != null;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, ?nb]),
      builder: (context, _) => Align(
        alignment: Alignment.centerLeft,
        child: PopupMenuButton<String>(
          key: const ValueKey('settings-menu'),
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_rounded),
          onSelected: (id) {
            if (id == _aboutId && microsoft != null) {
              unawaited(showAboutNoted(context, microsoft!));
              return;
            }
            final theme = themeCommands(settings);
            final toolbar = toolbarCommands(settings);
            if (theme[id] != null) {
              theme.invoke(id);
            } else if (toolbar[id] != null) {
              toolbar.invoke(id);
            } else if (nb != null) {
              _guard(context, () => folderSettingsCommands(nb).invoke(id));
            }
          },
          itemBuilder: (context) {
            final theme = themeCommands(settings);
            final toolbar = toolbarCommands(settings);
            Widget check(Command c) => SizedBox(
              width: NotedMetrics.of(context).icon,
              child: (c.checked ?? false)
                  ? Icon(
                      Icons.check_rounded,
                      size: NotedMetrics.of(context).icon,
                    )
                  : null,
            );
            return [
              const NotedMenuHeading('Theme'),
              for (final s in ThemeSetting.values)
                NotedMenuItem<String>(
                  key: ValueKey('theme-${s.value}'),
                  value: AppCommands.themeId(s),
                  label: theme[AppCommands.themeId(s)]!.label,
                  leading: check(theme[AppCommands.themeId(s)]!),
                ),
              const NotedMenuHeading('Toolbar'),
              for (final s in ToolbarStyle.values)
                NotedMenuItem<String>(
                  key: ValueKey('toolbar-${s.value}'),
                  value: AppCommands.toolbarId(s),
                  label: toolbar[AppCommands.toolbarId(s)]!.label,
                  leading: check(toolbar[AppCommands.toolbarId(s)]!),
                ),
              if (canPick) ...[
                const NotedMenuHeading('Default page folder'),
                NotedMenuItem<String>(
                  key: const ValueKey('settings-default-page-folder'),
                  value: AppCommands.defaultPageFolder,
                  label: nb.newPageFolderPath,
                  icon: Icons.folder_open_rounded,
                ),
                const NotedMenuHeading('Default binder folder'),
                NotedMenuItem<String>(
                  key: const ValueKey('settings-default-binder-folder'),
                  value: AppCommands.defaultBinderFolder,
                  label: nb.defaultBinderFolderPath,
                  icon: Icons.folder_open_rounded,
                ),
              ],
              if (microsoft != null) ...[
                const NotedMenuDivider(),
                const NotedMenuItem<String>(
                  key: ValueKey('settings-about'),
                  value: _aboutId,
                  label: 'About Noted',
                  icon: Icons.info_outline_rounded,
                ),
              ],
            ];
          },
        ),
      ),
    );
  }

  /// Runs [action], showing a [NotebookException] in a SnackBar.
  Future<void> _guard(BuildContext context, Future<Object?> Function() action) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await action();
    } on NotebookException catch (e) {
      messenger?.hideCurrentSnackBar();
      messenger?.showSnackBar(SnackBar(content: Text(e.message)));
    }
  }
}
