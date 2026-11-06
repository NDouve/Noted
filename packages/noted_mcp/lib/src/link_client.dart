// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core_read.dart';

import 'running_probe.dart';

/// The one way the server asks the app for anything (invariant 4): a request
/// over the local link (`ai_link.dart` in the core, protocol `ai-link/2`).
/// Every request that carries a code goes this way, so the app checks the
/// code, its expiry and its approval and logs the use; while Noted runs the
/// server never decides, and never writes a file.
///
/// This is the only file in the server that opens a socket, and it connects
/// to `127.0.0.1` only; the invariant tests check both.
///
/// The code is sent only after the peer has shown it can read
/// `ai-link.json` (its greeting carries the file's nonce), so it isn't a
/// stranger on a stale port. The code never appears in anything this returns.
final class AiLinkClient {
  AiLinkClient(
    this.dataDir, {
    required this.session,
    this.app,
    this.connectTimeout = const Duration(seconds: 2),
    this.greetingTimeout = const Duration(seconds: 2),
    // The app may wait for the user to allow a new session (up to
    // [aiLinkApprovalTimeout]) before it answers.
    this.responseTimeout = const Duration(seconds: 55),
  });

  /// The app's data folder, where `ai-link.json` is.
  final Directory dataDir;

  /// This server process's random session id, sent with every request.
  final String session;

  /// The MCP client's name, sent with every request if known.
  final String? app;

  final Duration connectTimeout;
  final Duration greetingTimeout;
  final Duration responseTimeout;

  /// The failure for an app that can't be reached.
  static AiLinkError get notRunning => AiLinkError(AiLinkCode.notRunning);

  /// The failure for an app that was reached but gave no usable answer.
  static AiLinkError get noAnswer => AiLinkError(
    AiLinkCode.unknown,
    "Noted didn't answer. If you were writing, the write may not have happened.",
    'no_answer',
  );

  /// Sends [request] and returns the app's answer, or an [AiLinkError] with
  /// [AiLinkCode.notRunning] if the app can't be reached (nothing is then
  /// sent), or [noAnswer].
  Future<AiLinkResponse> send(AiLinkRequest request) async {
    final line = request.encode();
    if (utf8.encode(line).length + 1 > aiLinkMaxRequestBytes) {
      return AiLinkError(
        AiLinkCode.badRequest,
        'The request is too long to send in one piece. For a write, send it in smaller parts with mode "append".',
      );
    }
    final link = await _readLink();
    if (link == null) return notRunning;

    final socket = await _connect(link.port);
    if (socket == null) return notRunning;
    final lines = _Lines(StreamIterator(socket));
    try {
      final greeting = await lines.next(4096).timeout(greetingTimeout, onTimeout: () => null);
      // The nonce shows the peer could read ai-link.json, so it isn't a
      // stranger on a stale port. Anything else gets nothing, least of all
      // the code.
      if (greeting == null || readAiLinkGreeting(greeting) != link.nonce) return notRunning;

      socket.write('$line\n');
      await socket.flush().timeout(responseTimeout);
      final answer = await lines.next(aiLinkMaxRequestBytes).timeout(responseTimeout, onTimeout: () => null);
      if (answer == null) return noAnswer;
      return AiLinkResponse.decode(answer) ?? noAnswer;
    } on Object {
      return noAnswer;
    } finally {
      await lines.close();
      socket.destroy();
    }
  }

  /// Whether the link file is there and its port answers with the greeting
  /// that carries the file's nonce. Nothing is sent. A missing or stale file,
  /// or no greeting, is false.
  Future<bool> greets() async {
    final link = await _readLink();
    if (link == null) return false;
    final socket = await _connect(link.port);
    if (socket == null) return false;
    final lines = _Lines(StreamIterator(socket));
    try {
      final greeting = await lines.next(4096).timeout(greetingTimeout, onTimeout: () => null);
      return greeting != null && readAiLinkGreeting(greeting) == link.nonce;
    } on Object {
      return false;
    } finally {
      await lines.close();
      socket.destroy();
    }
  }

  // The one connection this client makes: loopback only.
  Future<Socket?> _connect(int port) async {
    try {
      return await Socket.connect(InternetAddress.loopbackIPv4, port, timeout: connectTimeout);
    } on Object {
      return null;
    }
  }

  Future<({int port, String nonce})?> _readLink() async {
    try {
      // Never the running-lock file itself (a synced link to it).
      final identity = await LockIdentity.of(dataDir);
      final bytes = await identity.readBytes('${dataDir.path}${Platform.pathSeparator}$aiLinkFileName');
      if (bytes == null) return null;
      return readAiLink(utf8.decode(bytes));
    } on Object {
      return null;
    }
  }
}

/// Newline-terminated lines from a byte stream, each at most a given size.
final class _Lines {
  _Lines(this._it);

  final StreamIterator<List<int>> _it;
  final List<int> _buf = [];

  /// The next line without its newline, or null if the stream ends or the
  /// line is longer than [max] bytes.
  Future<String?> next(int max) async {
    while (true) {
      final i = _buf.indexOf(10);
      if (i > max || (i < 0 && _buf.length > max)) return null;
      if (i >= 0) {
        final line = utf8.decode(_buf.sublist(0, i), allowMalformed: true);
        _buf.removeRange(0, i + 1);
        return line;
      }
      if (!await _it.moveNext()) return null;
      _buf.addAll(_it.current);
    }
  }

  Future<void> close() async {
    try {
      await _it.cancel();
    } on Object {
      // Already closed.
    }
  }
}
