// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'src/home.dart';
import 'src/notebook.dart';

/// The box modules compiled into this build (0034, stage 1).
ModuleRegistry buildModules() =>
    ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true)
      ..register(DrawingModule());

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notebook = Notebook(
    PageStore(defaultPagesDirectory()),
    buildModules(),
    bindersFile: defaultBindersFile(),
    pickFolder: () => getDirectoryPath(confirmButtonText: 'Use as binder'),
    watchFiles: true,
  );
  runApp(NotedApp(notebook: notebook));
  await notebook.load();
}

class NotedApp extends StatefulWidget {
  const NotedApp({super.key, required this.notebook});

  final Notebook notebook;

  @override
  State<NotedApp> createState() => _NotedAppState();
}

class _NotedAppState extends State<NotedApp> {
  late final AppLifecycleListener _lifecycle;

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
    return MaterialApp(
      title: 'Noted',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(colorSchemeSeed: const Color(0xFF3F51B5), useMaterial3: true),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        ...noteLocalizationsDelegates,
      ],
      supportedLocales: const [Locale('en')],
      home: Home(notebook: widget.notebook),
    );
  }
}
