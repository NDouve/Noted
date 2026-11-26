// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

// Makes the host tests publish the way Android does when SELinux refuses
// `link` (run 2026-11-25-01, task 1): the Android branch on any platform, the
// publisher registered, every `link` refused with EACCES, and the no-replace
// rename taken by lstat then rename.
import 'package:noted_core/noted_core.dart';
import 'package:noted_core/src/storage/exclusive_move.dart' show MoveStrategy, debugMoveStrategy, debugNoReplaceErrno;
import 'package:noted_core/src/storage/exclusive_publish.dart'
    show debugLinkCalls, debugLinkErrno, debugPublishAsAndroid, nonLinkPublisher;

/// Takes the Android path: [linkErrno] is what every `link` call gives (13,
/// EACCES, as SELinux does; null lets `link` work), and [strategy] how the
/// rename then goes; [register] false leaves no publisher registered, so the
/// publish itself throws. Call [resetAndroidPublish] after.
void useAndroidPublish({int? linkErrno = 13, MoveStrategy? strategy = MoveStrategy.lstatRename, bool register = true}) {
  debugPublishAsAndroid = true;
  nonLinkPublisher = null;
  if (register) useRenamePublishOnAndroid();
  debugLinkErrno = linkErrno;
  debugMoveStrategy = strategy;
  debugLinkCalls = 0;
}

/// Puts everything [useAndroidPublish] changed back.
void resetAndroidPublish() {
  debugPublishAsAndroid = null;
  nonLinkPublisher = null;
  debugLinkErrno = null;
  debugNoReplaceErrno = null;
  debugMoveStrategy = null;
  debugLinkCalls = 0;
}

/// How many times a publish tried `link` since [useAndroidPublish].
int get androidLinkCalls => debugLinkCalls;
