// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

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
        child: PopupMenuButton<ThemeSetting>(
          key: const ValueKey('settings-menu'),
          tooltip: 'Settings',
          icon: const Icon(Icons.settings_outlined),
          onSelected: (v) => settings.theme = v,
          itemBuilder: (_) => [
            const PopupMenuItem<ThemeSetting>(
              enabled: false,
              height: 32,
              child: Text('Theme'),
            ),
            for (final s in ThemeSetting.values)
              CheckedPopupMenuItem<ThemeSetting>(
                key: ValueKey('theme-${s.value}'),
                value: s,
                checked: settings.theme == s,
                child: Text(s.label),
              ),
          ],
        ),
      ),
    );
  }
}
