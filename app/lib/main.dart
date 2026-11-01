// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io' show Directory, File, Platform;
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_template/noted_box_template.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'src/ai/ai_link_server.dart';
import 'src/app_settings.dart';
import 'src/attachment_platform.dart';
import 'src/app_theme.dart';
import 'src/home.dart';
import 'src/notebook.dart';
import 'src/recovery_notice.dart';
import 'src/recovery_store.dart';

/// The box modules compiled into this build (0034, stage 1).
///
/// TODO(ai-phase-2): after the merge, register the AI box module here:
/// `..register(AiModule(connections: aiConnections!))` from noted_box_ai (do
/// not import it before then). [aiConnections] is `settings.aiConnections`.
ModuleRegistry buildModules({ValueListenable<List<AiConnectionInfo>>? aiConnections}) =>
    ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true)
      ..register(DrawingModule())
      // Images before files: a picture becomes an image box, anything else a
      // file box (BoxModule.fileAffinity).
      ..register(const ImageModule())
      ..register(const FileModule())
      // The template box module (docs/box-modules.md): compiled in, off by
      // default. Set enabled: true to try it.
      ..register(const StickyLabelModule(), enabled: false);

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
  // The bundled Inter font is SIL OFL 1.1; its licence ships with it.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['Inter'],
      await rootBundle.loadString('assets/fonts/Inter/OFL.txt'),
    );
  });
  final settings = AppSettings(defaultSettingsFile());
  final notebook = Notebook(
    PageStore(defaultPagesDirectory()),
    buildModules(aiConnections: settings.aiConnections),
    bindersFile: defaultBindersFile(),
    recoveryDirectory: defaultRecoveryDirectory(defaultBindersFile()),
    pickFolder: () => getDirectoryPath(confirmButtonText: 'Use this folder'),
    watchFiles: true,
    deviceName: computerName(),
    settings: settings,
    cacheDirectory: defaultCacheDirectory(),
    attachmentPicker: pickAttachments,
    attachmentOpener: openWithDefaultApp,
  );
  FileClipboard.read = readClipboardFiles;
  final aiLink = await startAiLink(notebook, defaultSettingsFile().parent);
  runApp(NotedApp(notebook: notebook, settings: settings, aiLink: aiLink));
  await notebook.load();
}

/// Starts the local link the MCP server writes through (invariant 4), with
/// `ai-link.json` in [dataFolder]. Returns null, with a log line that holds no
/// secrets, if it can't bind; the app then runs without it.
Future<AiLinkServer?> startAiLink(Notebook notebook, Directory dataFolder) async {
  final server = AiLinkServer(
    file: File('${dataFolder.path}${Platform.pathSeparator}$aiLinkFileName'),
    handler: notebook.aiWrite,
  );
  try {
    await server.start();
    return server;
  } on Object catch (e) {
    debugPrint('Noted: the AI link could not start: ${e.runtimeType}');
    return null;
  }
}

class NotedApp extends StatefulWidget {
  const NotedApp({super.key, required this.notebook, this.settings, this.aiLink});

  final Notebook notebook;

  /// The local link for AI writes; stopped (and its file removed) when the
  /// app exits cleanly. Null: none is running.
  final AiLinkServer? aiLink;

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
        await widget.aiLink?.dispose();
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
    // The last input being touch grows controls to 44px and rows to 40px.
    return ValueListenableBuilder<bool>(
      valueListenable: InputModeNotifier.instance,
      builder: (context, touch, _) => _materialApp(touch),
    );
  }

  Widget _materialApp(bool touch) {
    return MaterialApp(
      title: 'Noted',
      navigatorKey: _navigatorKey,
      debugShowCheckedModeBanner: false,
      theme: buildNotedTheme(Brightness.light, touch: touch),
      darkTheme: buildNotedTheme(Brightness.dark, touch: touch),
      themeMode: _settings.themeMode,
      builder: (context, child) => InputModeScope(child: child!),
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
