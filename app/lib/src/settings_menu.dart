// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMetrics;

import 'app_commands.dart';
import 'app_settings.dart';

/// The gear at the bottom of the sidebar: a menu to choose the theme.
class SettingsMenu extends StatelessWidget {
  const SettingsMenu({super.key, required this.settings});

  final AppSettings settings;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: settings,
      builder: (context, _) => Align(
        alignment: Alignment.centerLeft,
        child: PopupMenuButton<String>(
          key: const ValueKey('settings-menu'),
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onSelected: (id) => themeCommands(settings).invoke(id),
          itemBuilder: (context) {
            final theme = themeCommands(settings);
            return [
              PopupMenuItem<String>(
                enabled: false,
                height: NotedMetrics.of(context).row,
                child: Text('Theme'),
              ),
              for (final s in ThemeSetting.values)
                CheckedPopupMenuItem<String>(
                  key: ValueKey('theme-${s.value}'),
                  value: AppCommands.themeId(s),
                  checked: theme[AppCommands.themeId(s)]!.checked ?? false,
                  child: Text(theme[AppCommands.themeId(s)]!.label),
                ),
            ];
          },
        ),
      ),
    );
  }
}
