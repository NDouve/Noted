// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:noted_canvas/noted_canvas.dart' show NotedMenuHeading, NotedMenuItem, NotedMetrics;

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
          icon: const Icon(Icons.settings_rounded),
          onSelected: (id) => themeCommands(settings).invoke(id),
          itemBuilder: (context) {
            final theme = themeCommands(settings);
            return [
              const NotedMenuHeading('Theme'),
              for (final s in ThemeSetting.values)
                NotedMenuItem<String>(
                  key: ValueKey('theme-${s.value}'),
                  value: AppCommands.themeId(s),
                  label: theme[AppCommands.themeId(s)]!.label,
                  leading: SizedBox(
                    width: NotedMetrics.of(context).icon,
                    child: (theme[AppCommands.themeId(s)]!.checked ?? false)
                        ? Icon(
                            Icons.check_rounded,
                            size: NotedMetrics.of(context).icon,
                          )
                        : null,
                  ),
                ),
            ];
          },
        ),
      ),
    );
  }
}
