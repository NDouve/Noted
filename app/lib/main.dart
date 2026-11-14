// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async' show unawaited;
import 'dart:io' show Directory, File, Platform, exit;
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
import 'src/link_log.dart';
import 'src/microsoft_account.dart';
import 'src/notebook.dart';
import 'src/onedrive_sync.dart';
import 'src/open_files.dart';
import 'src/recovery_lock.dart';
import 'src/recovery_notice.dart';
import 'src/recovery_store.dart';
import 'src/save_trouble_bar.dart';

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
  // --- One process owns recovery (R-1 v5, 3.1) ---------------------------
  // Taken before anything is built and held for the life of the process. A
  // second process says so and quits; a lock that can't be taken for another
  // reason lets Noted run with recovery refused (state 4 with the cause).
  final recoveryLock = RecoveryLock.besides(defaultRecoveryDirectory(defaultBindersFile()));
  if (recoveryLock.acquireSync() == RecoveryLockResult.heldByOther) {
    runApp(AlreadyOpenApp(hadFiles: args.isNotEmpty));
    return;
  }
  // --- end -------------------------------------------------------------------
  installLinkLog();
  final settings = AppSettings(defaultSettingsFile());
  final notebook = buildAppNotebook(settings: settings, recoveryLock: recoveryLock);
  FileClipboard.read = readClipboardFiles;
  final openFiles = OpenFileService(notebook);
  // Null in a build without NOTED_MS_CLIENT_ID: no Microsoft sign-in at all.
  final microsoft = MicrosoftAccount.create();
  // Mobile builds with a client id only: the OneDrive pull (sync stage 3).
  final sync = buildOneDriveSync(notebook, microsoft);
  await openWhenOwned(
    notebook,
    defaultAiDataFolder(),
    show: runApp,
    settings: settings,
    openFiles: openFiles,
    microsoft: microsoft,
    sync: sync,
    args: args,
    // Its first-launch clean-up can write settings.json: not before the lock.
    onOwned: () {
      if (microsoft != null) unawaited(microsoft.start(settings: settings));
    },
  );
  // After the first frame, so the window can show the questions.
  WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(notebook.askPendingAiApprovals()));
}

/// Shown instead of the app when another Noted process already owns the
/// recovery folder (R-1 v5): there is only the one choice.
class AlreadyOpenApp extends StatelessWidget {
  const AlreadyOpenApp({super.key, this.hadFiles = false});

  /// A file was named on the command line: it is not opened by this process.
  final bool hadFiles;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Noted',
    debugShowCheckedModeBanner: false,
    theme: buildNotedTheme(Brightness.light, touch: false),
    darkTheme: buildNotedTheme(Brightness.dark, touch: false),
    themeMode: ThemeMode.system,
    home: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Noted is already open.', key: ValueKey('already-open-text')),
            if (hadFiles)
              const Text('Open the file from there.', key: ValueKey('already-open-file')),
            const SizedBox(height: 16),
            FilledButton(
              key: const ValueKey('already-open-quit'),
              autofocus: true,
              onPressed: () => exit(0),
              child: const Text('Quit'),
            ),
          ],
        ),
      ),
    ),
  );
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
Notebook buildAppNotebook({
  AppSettings? settings,
  Directory? pagesDirectory,
  File? bindersFile,
  RecoveryLock? recoveryLock,
}) {
  final binders = bindersFile ?? defaultBindersFile();
  // The one lock the notebook and the OneDrive pull share (stage 3, G11). On
  // a device the working copies are read-only here while the sync only pulls.
  final oneDriveRoot = deviceOneDriveRoot();
  late final Notebook notebook;
  final aiAccess = isMobilePlatform
      ? null
      : AiAccessService(
          dataFolder: defaultAiDataFolder(binders),
          pageOfBox: (id) => notebook.aiPageOfBox(id),
          // Polling (which trims the log and prunes codes) starts in
          // openWhenOwned, once the running lock is held.
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
    recoveryLock: recoveryLock,
    folderLocks: FolderLocks(),
    readOnlyRoots: isMobilePlatform && oneDriveRoot != null ? [oneDriveRoot.path] : const [],
  );
}

/// The OneDrive pull of this build: null on desktop, in a build without a
/// client id (no [microsoft]) and when the device's folders aren't known.
/// It uses the notebook's own [FolderLocks].
OneDriveSync? buildOneDriveSync(Notebook notebook, MicrosoftAccount? microsoft) {
  if (!isMobilePlatform || microsoft == null) return null;
  final root = deviceOneDriveRoot();
  final support = deviceSupportDirectory();
  if (root == null || support == null) return null;
  return OneDriveSync.create(notebook: notebook, microsoft: microsoft, workingRoot: root, support: support);
}

/// Starts the app in the one order that keeps `noted_mcp` out of an open page
/// (run 2026-11-06-02):
///
/// 1. try the running lock once; if another process holds it, [show] a
///    [WaitingForLockApp] and wait for it with no limit (a server's hold ends
///    within seconds), so nothing is built, read or written meanwhile;
/// 2. start the access service's polling (it trims the log and prunes revoked
///    codes, both writes) and, unless [startLink] is false, the local link, so
///    a link that answers implies the lock is held;
/// 3. [show] the app, then load the notebook and open the files named in [args].
///
/// On mobile there is no lock, no link and no MCP server (0129), so nothing waits.
Future<({AiRunningLock? lock, AiLinkServer? link})> openWhenOwned(
  Notebook notebook,
  Directory dataFolder, {
  required void Function(Widget) show,
  bool startLink = true,
  AppSettings? settings,
  OpenFileService? openFiles,
  MicrosoftAccount? microsoft,
  OneDriveSync? sync,
  List<String> args = const [],
  VoidCallback? onOwned,
}) async {
  AiRunningLock? lock;
  if (!isMobilePlatform) {
    // Held until the app exits: it tells noted_mcp that Noted is running.
    lock = appRunningLock = AiRunningLock(dataFolder);
    if (!lock.acquire(tries: 1)) {
      show(WaitingForLockApp(lock: lock));
      await lock.waitHeld();
      // Disposed while waiting: never poll, link or load without the lock.
      if (!lock.held) return (lock: lock, link: null);
    }
    notebook.aiAccess?.startPolling(const Duration(seconds: 3));
  }
  onOwned?.call();
  final link = lock != null && startLink ? await startAiLink(notebook, dataFolder) : null;
  show(NotedApp(notebook: notebook, settings: settings, aiLink: link, runningLock: lock, openFiles: openFiles, microsoft: microsoft, sync: sync));
  // A load that fails or hangs shows its error screen, with Retry.
  await notebook.loadChecked();
  // Only now: it adds its folder to the loaded notebook and starts polling.
  if (sync != null && notebook.loadError == null) unawaited(sync.start());
  // Files named on the command line, then those a second launch hands over.
  if (!isMobilePlatform) unawaited(openFiles?.start(args));
  return (lock: lock, link: link);
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
/// with the window without ever reporting that it closed). False: the user chose
/// to stay (the question Your changes will be lost), and nothing is dropped.
Future<bool> saveBeforeExit(Notebook notebook) async {
  if (!await notebook.prepareToExit()) return false;
  await notebook.discardPendingDelete();
  return true;
}

class NotedApp extends StatefulWidget {
  const NotedApp({super.key, required this.notebook, this.settings, this.aiLink, this.runningLock, this.openFiles, this.microsoft, this.sync});

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

  /// The Microsoft account of a build with a client id; null hides sign-in.
  final MicrosoftAccount? microsoft;

  /// The OneDrive pull (mobile builds with a client id); null elsewhere.
  final OneDriveSync? sync;

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
    // Questions about changes that couldn't be saved (R-1 v5) are asked here too.
    widget.notebook.questioner = (q, title) => showTroubleQuestion(_navigatorKey, q, title);
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
        // --- Saving at quit has a time limit (R-1 v5) ---------------------------
        // What doesn't save goes to recovery as on leaving a page; the question
        // "Your changes will be lost" can cancel the quit (and keeps a pending delete).
        if (!await saveBeforeExit(widget.notebook)) return AppExitResponse.cancel;
        try {
          await showRecoveryNoticeOnExit(widget.notebook, _navigatorKey);
        } on Object catch (e) {
          debugPrint('The exit notice failed: $e');
        }
        // --- end ---------------------------------------------------------------
        await widget.aiLink?.dispose();
        widget.runningLock?.release();
        return AppExitResponse.exit;
      },
      onHide: widget.notebook.flush,
      // A binder list that could not be read is read again.
      onResume: () => unawaited(widget.notebook.retrySettings()),
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
      builder: (context, child) => OneDriveScope(sync: widget.sync, child: InputModeScope(child: child!)),
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        ...noteLocalizationsDelegates,
      ],
      supportedLocales: const [Locale('en')],
      home: Home(notebook: widget.notebook, settings: _settings, microsoft: widget.microsoft),
    );
  }
}
