// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';

import 'commands.dart';

/// Commands the built-in toolbars name that nothing provides yet, with the
/// label and icon of their disabled placeholder. Once a module registers
/// one of these ids, its command replaces the placeholder.
const Map<String, (String, IconData, {bool showLabel})> toolbarPlaceholders = {
  'noted.note.textColor': (
    'Text colour',
    Icons.format_color_text_rounded,
    showLabel: false,
  ),
  'noted.note.link': ('Link', Icons.link_rounded, showLabel: false),
  'noted.image.insert': ('Image', Icons.image_rounded, showLabel: true),
  'noted.file.insert': ('File', Icons.attach_file_rounded, showLabel: true),
  'noted.ai.insert': ('AI box', Icons.auto_awesome_rounded, showLabel: true),
  'noted.encrypted.insert': (
    'Encrypted box',
    Icons.lock_rounded,
    showLabel: true,
  ),
  'noted.drawing.highlighter': (
    'Highlighter',
    Icons.border_color_rounded,
    showLabel: false,
  ),
  'noted.drawing.lasso': ('Lasso select', Icons.gesture_rounded, showLabel: false),
};

/// Disabled "coming later" commands for the [toolbarPlaceholders] that
/// [registry] doesn't have.
List<Command> placeholderCommands(CommandRegistry registry) => [
  for (final MapEntry(key: id, value: (label, icon, :showLabel))
      in toolbarPlaceholders.entries)
    if (registry[id] == null)
      Command(
        id: id,
        label: '$label (coming later)',
        icon: icon,
        text: showLabel ? () => label : null,
        enabled: () => false,
        invoke: () {},
      ),
];
