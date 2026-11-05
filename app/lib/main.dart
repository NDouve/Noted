// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async' show unawaited;
import 'dart:io' show Directory, File, Platform;
import 'dart:ui';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:noted_box_ai/noted_box_ai.dart';
import 'package:noted_box_attachments/noted_box_attachments.dart';
import 'package:noted_box_drawing/noted_box_drawing.dart';
import 'package:noted_box_note/noted_box_note.dart';
import 'package:noted_box_template/noted_box_template.dart';
import 'package:noted_canvas/noted_canvas.dart';
import 'package:noted_core/noted_core.dart';

import 'src/ai/ai_access_service.dart';
import 'src/ai/ai_approval_dialog.dart';
import 'src/ai/ai_link_server.dart';
import 'src/ai/ai_running_lock.dart';
import 'src/app_settings.dart';
import 'src/attachment_platform.dart';
import 'src/device_storage.dart';
import 'src/app_theme.dart';
import 'src/home.dart';
import 'src/notebook.dart';
import 'src/open_files.dart';
import 'src/recovery_notice.dart';
import 'src/recovery_store.dart';

/// The box modules compiled into this build (0034, stage 1).
///
/// [aiAccess] is what an AI box uses to manage its codes (per-box codes, the
/// activity log); none when null.
ModuleRegistry buildModules({AiBoxAccess? aiAccess}) =>
    ModuleRegistry()
      ..register(const NoteModule(), alwaysOn: true, isDefault: true)
      ..register(DrawingModule())
      // Images before files: a picture becomes an image box, anything else a
      // file box (BoxModule.fileAffinity).
      ..register(const ImageModule())
      ..register(const FileModule())
      ..register(AiModule(access: aiAccess))
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

/// The lock that tells `noted_mcp` Noted is running, kept for the whole
/// process (the OS lets go of it when the app exits or dies).
AiRunningLock? appRunningLock;

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  // The bundled Inter font is SIL OFL 1.1; its licence ships with it.
  LicenseRegistry.addLicense(() async* {
    yield LicenseEntryWithLineBreaks(
      const ['Inter'],
      await rootBundle.loadString('assets/fonts/Inter/OFL.txt'),
    );
  });
  // On a phone or tablet, finds the app's folders before any default path is
  // read (0129).
  try {
    await initDeviceStorage();
  } on Object catch (e) {
    runApp(StorageErrorApp(error: e));
    return;
  }
  final settings = AppSettings(defaultSettingsFile());
  final notebook = buildAppNotebook(settings: settings);
  FileClipboard.read = readClipboardFiles;
  final services = await startAiServices(notebook, defaultAiDataFolder());
  final openFiles = OpenFileService(notebook);
  runApp(NotedApp(notebook: notebook, settings: settings, aiLink: services.link, runningLock: services.lock, openFiles: openFiles));
  await notebook.load();
  // Files named on the command line, then those a second launch hands over.
  if (!isMobilePlatform) unawaited(openFiles.start(args));
  // After the first frame, so the window can show the questions.
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(notebook.askPendingAiApprovals()));
}

/// Shown instead of the app when the device's app folders can't be found, so
/// the launch isn't blank.
class StorageErrorApp extends StatelessWidget {
  const StorageErrorApp({super.key, required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      color: const Color(0xFFFFFFFF),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Text(
            "Noted can't find its storage folders on this device.\n\n$error",
            style: const TextStyle(color: Color(0xFF000000), fontSize: 16),
          ),
        ),
      ),
    ),
  );
}

/// The folder for `ai-access.json`, `ai-activity.json`, `ai-link.json` and the
/// running lock: beside `binders.json` (and `settings.json`) on desktop. Mobile
/// has no AI service, so nothing is written there.
Directory defaultAiDataFolder([File? bindersFile]) => (bindersFile ?? defaultBindersFile()).absolute.parent;

/// The notebook with this build's platform wiring (0129): on mobile there is
/// no AI access service (no MCP server), no folder watching and no folder
/// picker (neither file_selector's iOS nor its Android folder picker gives
/// a usable path). The folders default to the platform's; tests pass their
/// own.
Notebook buildAppNotebook({AppSettings? settings, Directory? pagesDirectory, File? bindersFile}) {
  final binders = bindersFile ?? defaultBindersFile();
  late final Notebook notebook;
  final aiAccess = isMobilePlatform
      ? null
      : AiAccessService(
          dataFolder: defaultAiDataFolder(binders),
          pageOfBox: (id) => notebook.aiPageOfBox(id),
          // Another Noted may change the codes or the log: show it.
          pollInterval: const Duration(seconds: 3),
        );
  return notebook = Notebook(
    PageStore(pagesDirectory ?? defaultPagesDirectory()),
    buildModules(aiAccess: aiAccess),
    bindersFile: binders,
    recoveryDirectory: defaultRecoveryDirectory(binders),
    pickFolder: isMobilePlatform ? null : () => getDirectoryPath(confirmButtonText: 'Use this folder'),
    watchFiles: !isMobilePlatform,
    deviceName: computerName(),
    settings: settings,
    aiAccess: aiAccess,
    cacheDirectory: defaultCacheDirectory(),
    attachmentPicker: pickAttachments,
    attachmentOpener: openWithDefaultApp,
  );
}

/// Starts what `noted_mcp` relies on: the running lock and the local link.
/// Neither runs on mobile (0129), which has no MCP server; both are null then.
Future<({AiRunningLock? lock, AiLinkServer? link})> startAiServices(Notebook notebook, Directory dataFolder) async {
  if (isMobilePlatform) return (lock: null, link: null);
  // Held until the app exits: it tells noted_mcp that Noted is running.
  final runningLock = appRunningLock = AiRunningLock(dataFolder)..acquire();
  // If another process held it for too long, keep trying, with a warning
  // on screen until it is ours.
  if (!runningLock.held) runningLock.startRetrying();
  return (lock: runningLock, link: await startAiLink(notebook, dataFolder));
}

/// Starts the local link the MCP server writes through (invariant 4), with
/// `ai-link.json` in [dataFolder]. Returns null, with a log line that holds no
/// secrets, if it can't bind; the app then runs without it.
Future<AiLinkServer?> startAiLink(Notebook notebook, Directory dataFolder) async {
  final server = AiLinkServer(
    file: File('${dataFolder.path}${Platform.pathSeparator}$aiLinkFileName'),
    handler: notebook.handleAiLink,
  );
  try {
    await server.start();
    return server;
  } on Object catch (e) {
    debugPrint('Noted: the AI link could not start: ${e.runtimeType}');
    return null;
  }
}

/// What the app does to the notebook before it exits: writes unsaved edits,
/// then drops a delete that Undo could still reach (its Deleted bar goes away
/// with the window without ever reporting that it closed).
Future<void> saveBeforeExit(Notebook notebook) async {
  await notebook.flush();
  await notebook.discardPendingDelete();
}

class NotedApp extends StatefulWidget {
  const NotedApp({super.key, required this.notebook, this.settings, this.aiLink, this.runningLock, this.openFiles});

  final Notebook notebook;

  /// The local link for AI writes; stopped (and its file removed) when the
  /// app exits cleanly. Null: none is running.
  final AiLinkServer? aiLink;

  /// The lock that says Noted is running; let go of when the app exits.
  final AiRunningLock? runningLock;

  /// Opens files named at launch or by a second launch; its notices show here.
  final OpenFileService? openFiles;

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
    // AI code approvals and per-write questions are asked in this window.
    widget.notebook.aiApprover = (request) => showAiApprovalDialog(_navigatorKey, request);
    widget.openFiles?.notify = (message) {
      final context = _navigatorKey.currentContext;
      if (context != null) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message)));
    };
    _lifecycle = AppLifecycleListener(
      // Write unsaved edits before the window closes.
      onExitRequested: () async {
        // Logged so a normal close (Alt+F4, the close button) can be told
        // apart from a crash in the `flutter run` console.
        debugPrint('Noted: window close requested; saving before exit.');
        await saveBeforeExit(widget.notebook);
        await showRecoveryNoticeOnExit(widget.notebook, _navigatorKey);
        await widget.aiLink?.dispose();
        widget.runningLock?.release();
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

  // The warning across the top while the running lock isn't held.
  Widget _withRunningWarning(Widget child) {
    final lock = widget.runningLock;
    if (lock == null) return child;
    return Column(
      children: [
        ListenableBuilder(
          listenable: lock,
          builder: (context, _) => lock.held ? const SizedBox.shrink() : const AiRunningLockBanner(),
        ),
        Expanded(child: child),
      ],
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
      builder: (context, child) => InputModeScope(child: _withRunningWarning(child!)),
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
