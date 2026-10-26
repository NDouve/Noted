// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io' show Platform;
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'src/app_settings.dart';
import 'src/app_theme.dart';
import 'src/home.dart';
import 'src/notebook.dart';
import 'src/recovery_notice.dart';
import 'src/recovery_store.dart';

/// The box modules compiled into this build (0034, stage 1).
ModuleRegistry buildModules() =>
    ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true)
      ..register(DrawingModule());

/// This computer's name, or null if it can't be found.
String? computerName() {
  String? name;
  try {
    name = Platform.localHostname;
  } on Object {
    name = null;
  }
  if (name == null || name.isEmpty) name = Platform.environment['COMPUTERNAME'];
  return name == null || name.isEmpty ? null : name;
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notebook = Notebook(
    PageStore(defaultPagesDirectory()),
    buildModules(),
    bindersFile: defaultBindersFile(),
    recoveryDirectory: defaultRecoveryDirectory(defaultBindersFile()),
    pickFolder: () => getDirectoryPath(confirmButtonText: 'Use this folder'),
    watchFiles: true,
    deviceName: computerName(),
  );
  runApp(NotedApp(notebook: notebook, settings: AppSettings(defaultSettingsFile())));
  await notebook.load();
}

class NotedApp extends StatefulWidget {
  const NotedApp({super.key, required this.notebook, this.settings});

  final Notebook notebook;

  /// This device's settings (the theme). Null: the defaults, not saved.
  final AppSettings? settings;

  @override
  State<NotedApp> createState() => _NotedAppState();
}

class _NotedAppState extends State<NotedApp> {
  late final AppLifecycleListener _lifecycle;
  final _navigatorKey = GlobalKey<NavigatorState>();
  late final AppSettings _settings = widget.settings ?? AppSettings(null);

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      // Write unsaved edits before the window closes.
      onExitRequested: () async {
        // Logged so a normal close (Alt+F4, the close button) can be told
        // apart from a crash in the `flutter run` console.
        debugPrint('Noted: window close requested; saving before exit.');
        await widget.notebook.flush();
        await showRecoveryNoticeOnExit(widget.notebook, _navigatorKey);
        return AppExitResponse.exit;
      },
      onHide: widget.notebook.flush,
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _settings,
      builder: (context, _) => _app(),
    );
  }

  Widget _app() {
    return MaterialApp(
      title: 'Noted',
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildNotedTheme(Brightness.light),
      darkTheme: buildNotedTheme(Brightness.dark),
      themeMode: _settings.themeMode,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        ...noteLocalizationsDelegates,
      ],
      supportedLocales: const [Locale('en')],
      home: Home(notebook: widget.notebook, settings: _settings),
    );
  }
}
