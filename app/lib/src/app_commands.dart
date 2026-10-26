// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'app_settings.dart';
import 'notebook.dart';

/// Ids of the app's commands (Box API 0.4 command registry).
abstract final class AppCommands {
  // Pages (the "Pages" header, and a page row's menu).
  static const String newPage = 'app.page.new';
  static const String newPageFromTemplate = 'app.page.newFromTemplate';
  static const String newSubpage = 'app.page.newSubpage';
  static const String newSubpageFromTemplate = 'app.page.newSubpageFromTemplate';
  static const String saveAsTemplate = 'app.page.saveAsTemplate';
  static const String rename = 'app.page.rename';
  static const String moveUp = 'app.page.moveUp';
  static const String moveDown = 'app.page.moveDown';
  static const String indent = 'app.page.indent';
  static const String outdent = 'app.page.outdent';
  static const String delete = 'app.page.delete';
  static const String moveToFolder = 'app.page.moveToFolder';

  /// Chooses a page's background: `app.page.background.dots`.
  static String backgroundId(PageBackground b) => 'app.page.background.${b.name}';

  // Binders (the "Pages" header, and a binder header's menu).
  static const String newBinder = 'app.binder.new';
  static const String newBinderInFolder = 'app.binder.newInFolder';
  static const String openBinder = 'app.binder.open';
  static const String newBinderFromTemplate = 'app.binder.newFromTemplate';
  static const String binderNewPage = 'app.binder.newPage';
  static const String binderNewPageFromTemplate =
      'app.binder.newPageFromTemplate';
  static const String binderCover = 'app.binder.cover';
  static const String binderSaveAsTemplate = 'app.binder.saveAsTemplate';
  static const String binderRemove = 'app.binder.remove';

  // Theme.
  // Default folders (the settings menu).
  static const String defaultPageFolder = 'app.settings.defaultPageFolder';
  static const String defaultBinderFolder = 'app.settings.defaultBinderFolder';

  static const String themeSystem = 'app.theme.system';
  static const String themeLight = 'app.theme.light';
  static const String themeDark = 'app.theme.dark';

  static String themeId(ThemeSetting s) => 'app.theme.${s.value}';
}

/// What the page tree can do that needs the screen (dialogs, asking for a
/// folder, snack bars). The sidebar implements it; the commands call it.
abstract interface class PageTreeActions {
  Future<void> newStandalonePage();
  Future<void> newPageFromTemplate();
  Future<void> newBinder();
  Future<void> newBinderInFolder();
  Future<void> openBinder();
  Future<void> newBinderFromTemplate();
  Future<void> newSubpage(PageMeta page);
  Future<void> newSubpageFromTemplate(PageMeta page);
  Future<void> saveAsTemplate(PageMeta page);
  Future<void> rename(PageMeta page);
  Future<void> indent(PageMeta page);
  Future<void> delete(PageMeta page);
  Future<void> moveToFolder(PageMeta page);
  Future<void> binderNewPage(BinderSection binder);
  Future<void> binderNewPageFromTemplate(BinderSection binder);
  Future<void> binderSaveAsTemplate(BinderSection binder);
  Future<void> binderRemove(BinderSection binder);
}

/// The commands of the "Pages" header: new page (Ctrl+N), new binder, new
/// binder in another folder and open binder (when this device can pick a
/// folder), and the same from a template.
CommandRegistry pagesHeaderCommands(Notebook nb, PageTreeActions a) {
  final canPickFolder = nb.pickFolder != null;
  return CommandRegistry()..registerAll([
    Command(
      id: AppCommands.newPage,
      label: 'New page',
      icon: Icons.add_rounded,
      // Works anywhere in the window, also in a note editor (the editor has
      // no Ctrl+N of its own) and on a read-only page.
      shortcut: const SingleActivator(LogicalKeyboardKey.keyN, control: true),
      alternateShortcuts: const [SingleActivator(LogicalKeyboardKey.keyN, meta: true)],
      whileEditing: true,
      whileReadOnly: true,
      invoke: a.newStandalonePage,
    ),
    Command(
      id: AppCommands.newPageFromTemplate,
      label: 'New page from template…',
      icon: Icons.note_add_rounded,
      invoke: a.newPageFromTemplate,
    ),
    Command(
      id: AppCommands.newBinder,
      label: 'New binder',
      icon: Icons.create_new_folder_rounded,
      invoke: a.newBinder,
    ),
    Command(
      id: AppCommands.newBinderInFolder,
      label: 'New binder in another folder…',
      icon: Icons.create_new_folder_rounded,
      enabled: () => canPickFolder,
      invoke: a.newBinderInFolder,
    ),
    Command(
      id: AppCommands.openBinder,
      label: 'Open binder…',
      icon: Icons.folder_open_rounded,
      enabled: () => canPickFolder,
      invoke: a.openBinder,
    ),
    Command(
      id: AppCommands.newBinderFromTemplate,
      label: 'New binder from template…',
      icon: Icons.create_new_folder_rounded,
      invoke: a.newBinderFromTemplate,
    ),
  ]);
}

/// The commands for page [p]'s menu, with the enabled states the menu shows
/// (a first page can't move up or indent, a top-level page can't outdent).
CommandRegistry pageCommands(Notebook nb, PageMeta p, PageTreeActions a) {
  final tree = nb.treeOfPage(p.id);
  final siblings = tree.siblingsOf(p.id);
  final i = siblings.indexWhere((s) => s.id == p.id);
  return CommandRegistry()..registerAll([
    Command(
      id: AppCommands.newSubpage,
      label: 'New subpage',
      icon: Icons.subdirectory_arrow_right_rounded,
      invoke: () => a.newSubpage(p),
    ),
    Command(
      id: AppCommands.newSubpageFromTemplate,
      label: 'New subpage from template…',
      icon: Icons.note_add_rounded,
      invoke: () => a.newSubpageFromTemplate(p),
    ),
    Command(
      id: AppCommands.saveAsTemplate,
      label: 'Save as template…',
      icon: Icons.bookmark_add_rounded,
      invoke: () => a.saveAsTemplate(p),
    ),
    Command(
      id: AppCommands.rename,
      label: 'Rename',
      icon: Icons.edit_rounded,
      invoke: () => a.rename(p),
    ),
    Command(
      id: AppCommands.moveUp,
      label: 'Move up',
      icon: Icons.arrow_upward_rounded,
      enabled: () => i > 0,
      invoke: () => nb.moveUp(p.id),
    ),
    Command(
      id: AppCommands.moveDown,
      label: 'Move down',
      icon: Icons.arrow_downward_rounded,
      enabled: () => i >= 0 && i < siblings.length - 1,
      invoke: () => nb.moveDown(p.id),
    ),
    Command(
      id: AppCommands.indent,
      label: 'Indent',
      icon: Icons.format_indent_increase_rounded,
      enabled: () => i > 0,
      invoke: () => a.indent(p),
    ),
    Command(
      id: AppCommands.outdent,
      label: 'Outdent',
      icon: Icons.format_indent_decrease_rounded,
      enabled: () => tree.parentIdOf(p.id) != null,
      invoke: () => nb.outdent(p.id),
    ),
    Command(
      id: AppCommands.moveToFolder,
      label: 'Move to folder…',
      icon: Icons.drive_file_move_rounded,
      enabled: () => nb.pickFolder != null,
      invoke: () => a.moveToFolder(p),
    ),
    Command(
      id: AppCommands.delete,
      label: 'Delete',
      icon: Icons.delete_outline_rounded,
      invoke: () => a.delete(p),
    ),
    for (final b in PageBackground.values)
      Command(
        id: AppCommands.backgroundId(b),
        label: 'Page background: ${pageBackgroundLabel(b)}',
        icon: pageBackgroundIcon(b),
        enabled: () => !nb.isReadOnlyPage(p.id),
        checked: () => p.background == b,
        invoke: () => nb.setBackground(p.id, b),
      ),
  ]);
}

/// The commands for binder [b]'s menu. A binder whose folder is away only
/// offers removing it from the sidebar.
CommandRegistry binderCommands(
  Notebook nb,
  BinderSection b,
  PageTreeActions a,
) {
  final registry = CommandRegistry();
  if (b.available) {
    registry.registerAll([
      Command(
        id: AppCommands.binderNewPage,
        label: 'New page',
        icon: Icons.add_rounded,
        invoke: () => a.binderNewPage(b),
      ),
      Command(
        id: AppCommands.binderNewPageFromTemplate,
        label: 'New page from template…',
        icon: Icons.note_add_rounded,
        invoke: () => a.binderNewPageFromTemplate(b),
      ),
      Command(
        id: AppCommands.binderCover,
        label: 'Open cover',
        icon: Icons.book_rounded,
        invoke: () => nb.showCover(b.path),
      ),
      Command(
        id: AppCommands.binderSaveAsTemplate,
        label: 'Save as template…',
        icon: Icons.bookmark_add_rounded,
        invoke: () => a.binderSaveAsTemplate(b),
      ),
    ]);
  }
  registry.register(
    Command(
      id: AppCommands.binderRemove,
      label: 'Remove from sidebar',
      icon: Icons.remove_circle_outline_rounded,
      invoke: () => a.binderRemove(b),
    ),
  );
  return registry;
}

/// The settings commands that change a default folder: each opens the folder
/// picker and stores the folder. A [NotebookException] (a folder that holds a
/// binder, or is missing) is thrown to the caller.
CommandRegistry folderSettingsCommands(Notebook nb) => CommandRegistry()
  ..registerAll([
    Command(
      id: AppCommands.defaultPageFolder,
      label: 'Default page folder',
      icon: Icons.folder_open_rounded,
      enabled: () => nb.pickFolder != null,
      invoke: () async {
        final path = await nb.pickFolder?.call();
        if (path != null) await nb.setDefaultPageFolder(path);
      },
    ),
    Command(
      id: AppCommands.defaultBinderFolder,
      label: 'Default binder folder',
      icon: Icons.folder_open_rounded,
      enabled: () => nb.pickFolder != null,
      invoke: () async {
        final path = await nb.pickFolder?.call();
        if (path != null) await nb.setDefaultBinderFolder(path);
      },
    ),
  ]);

/// The theme commands: Follow system, Light, Dark. The one in use is
/// checked.
CommandRegistry themeCommands(AppSettings settings) => CommandRegistry()
  ..registerAll([
    for (final s in ThemeSetting.values)
      Command(
        id: AppCommands.themeId(s),
        label: s.label,
        icon: switch (s) {
          ThemeSetting.system => Icons.brightness_auto_rounded,
          ThemeSetting.light => Icons.light_mode_rounded,
          ThemeSetting.dark => Icons.dark_mode_rounded,
        },
        checked: () => settings.theme == s,
        listenable: settings,
        invoke: () => settings.theme = s,
      ),
  ]);
