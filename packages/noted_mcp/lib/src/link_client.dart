// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:noted_core/noted_core_read.dart';

import 'tools.dart' show ToolOutput;

/// The one way the server changes anything (invariant 4): a write request to
/// the running Noted app, over the local link (`ai_link.dart` in the core).
///
/// This is the only file in the server that opens a socket, and it connects
/// to `127.0.0.1` only; the invariant tests check both. The server writes no
/// file: the app decides whether the write happens.
///
/// The token is sent only after the peer has shown it can read
/// `ai-link.json` (its greeting carries the file's nonce), so it isn't a
/// stranger on a stale port. The token never appears in anything this
/// returns.
final class AiLinkClient {
  AiLinkClient(
    this.dataDir, {
    this.connectTimeout = const Duration(seconds: 2),
    this.greetingTimeout = const Duration(seconds: 2),
    this.responseTimeout = const Duration(seconds: 20),
  });

  /// The app's data folder, where `ai-link.json` is.
  final Directory dataDir;
  final Duration connectTimeout;
  final Duration greetingTimeout;
  final Duration responseTimeout;

  /// What the AI is told when the app can't be reached.
  static const String notRunning = "Noted isn't running. Open Noted and try again; reads still work.";

  static const String noToken =
      'write_box needs a Noted AI connection token. Create one in Noted '
      '(gear menu > AI connections) and give it to this server as the '
      'NOTED_TOKEN environment variable.';

  static ToolOutput _error(String text) => (text: text, isError: true);

  /// Asks the app to write [content] (markdown) to the AI box [boxId].
  Future<ToolOutput> writeBox({
    required String? token,
    required String boxId,
    required String mode,
    required String content,
  }) async {
    if (token == null || parseAiToken(token) == null) return _error(noToken);
    final m = AiLinkMode.values.where((e) => e.name == mode);
    if (m.isEmpty) return _error('mode must be "replace" or "append".');
    if (boxId.isEmpty) return _error('box_id is required.');
    final line = AiLinkRequest(token: token.trim(), box: boxId, mode: m.first, content: content).encode();
    if (utf8.encode(line).length + 1 > aiLinkMaxRequestBytes) {
      return _error('The content is too long to send in one write. Send it in smaller parts with mode "append".');
    }

    final link = await _readLink();
    if (link == null) return _error(notRunning);

    Socket? socket;
    try {
      socket = await Socket.connect(InternetAddress.loopbackIPv4, link.port, timeout: connectTimeout);
    } on Object {
      return _error(notRunning);
    }
    final lines = _Lines(StreamIterator(socket));
    try {
      final greeting = await lines.next(4096).timeout(greetingTimeout, onTimeout: () => null);
      // The nonce shows the peer could read ai-link.json, so it isn't a
      // stranger on a stale port. Anything else gets nothing, least of all
      // the token.
      if (greeting == null || readAiLinkGreeting(greeting) != link.nonce) return _error(notRunning);

      socket.write('$line\n');
      await socket.flush().timeout(responseTimeout);
      final answer = await lines.next(65536).timeout(responseTimeout, onTimeout: () => null);
      if (answer == null) return _error("Noted didn't answer. The write may not have happened; read the box to check.");
      final response = AiLinkResponse.decode(answer);
      if (response == null) return _error("Noted's answer wasn't understood.");
      if (!response.ok) return _error(response.message ?? response.code!.defaultMessage);
      return (text: 'Written to box ${response.box} on page ${response.page}.', isError: false);
    } on Object {
      return _error("Noted didn't answer. The write may not have happened; read the box to check.");
    } finally {
      await lines.close();
      socket.destroy();
    }
  }

  Future<({int port, String nonce})?> _readLink() async {
    try {
      final f = File('${dataDir.path}${Platform.pathSeparator}$aiLinkFileName');
      if (!await f.exists()) return null;
      return readAiLink(await f.readAsString());
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
