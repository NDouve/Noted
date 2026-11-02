// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:noted_core/noted_core.dart';

/// Answers an [AiLinkRequest]; the notebook's `handleAiLink`. `clientOpen`
/// says whether the client is still connected (a write is not applied once it
/// has gone).
typedef AiLinkHandler = Future<AiLinkResponse> Function(AiLinkRequest request, bool Function() clientOpen);

/// The app's end of the local link to the MCP server (invariant 4; the
/// protocol and the rules this follows are in `ai_link.dart`).
///
/// It listens on 127.0.0.1 only, on a free port, and writes the port and a
/// fresh nonce to [file] (`ai-link.json`). Every connection gets the greeting
/// with the nonce first, then reads one request line, answers it and closes.
class AiLinkServer {
  AiLinkServer({
    required this.file,
    required this.handler,
    this.readTimeout = aiLinkReadTimeout,
    this.maxRequestBytes = aiLinkMaxRequestBytes,
    this.maxConnections = aiLinkMaxConnections,
    this.recheckInterval = const Duration(seconds: 10),
  });

  /// How often to look for a missing [file] and write it again.
  final Duration recheckInterval;
  Timer? _recheck;

  /// `ai-link.json`, in the data folder next to settings.json.
  final File file;
  final AiLinkHandler handler;
  final Duration readTimeout;
  final int maxRequestBytes;
  final int maxConnections;

  ServerSocket? _server;
  String? _nonce;
  final Set<Socket> _open = {};

  /// The port, once started.
  int? get port => _server?.port;

  /// The nonce of this launch, once started.
  String? get nonce => _nonce;

  /// Binds the port and writes the file. Throws if it can't; the caller logs
  /// that and goes on without the link.
  Future<void> start() async {
    if (_server != null) return;
    final server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final nonce = base64Url
        .encode(List<int>.generate(32, (_) => random.nextInt(256)))
        .replaceAll('=', '');
    try {
      _writeFile(server.port, nonce);
    } on Object {
      await server.close();
      rethrow;
    }
    _server = server;
    _nonce = nonce;
    server.listen(_accept, onError: (Object _) {}, cancelOnError: false);
    // Another Noted that exits cleanly deletes the file; put it back, but
    // never replace a file that is there.
    _recheck = Timer.periodic(recheckInterval, (_) {
      if (_server == null || file.existsSync()) return;
      try {
        _writeFile(server.port, nonce);
      } on Object catch (e) {
        debugPrint('Noted: could not rewrite $aiLinkFileName: ${e.runtimeType}');
      }
    });
  }

  void _writeFile(int port, String nonce) {
    file.parent.createSync(recursive: true);
    final tmp = File('${file.path}.tmp');
    tmp.writeAsStringSync(
      jsonEncode({'format': 1, 'port': port, 'pid': pid, 'nonce': nonce}),
      flush: true,
    );
    tmp.renameSync(file.path);
  }

  /// Stops listening, drops the connections and deletes the file (if it is
  /// still this launch's).
  Future<void> dispose() async {
    final server = _server;
    _server = null;
    _recheck?.cancel();
    _recheck = null;
    if (server == null) return;
    await server.close();
    for (final s in _open.toList()) {
      s.destroy();
    }
    _open.clear();
    try {
      if (file.existsSync() && readAiLink(file.readAsStringSync())?.nonce == _nonce) {
        file.deleteSync();
      }
    } on Object catch (e) {
      debugPrint('Noted: could not remove $aiLinkFileName: ${e.runtimeType}');
    }
  }

  void _accept(Socket socket) {
    if (_open.length >= maxConnections) {
      socket.destroy();
      return;
    }
    _open.add(socket);
    unawaited(_serve(socket));
  }

  Future<void> _serve(Socket socket) async {
    // A write to a client that is already gone fails after the call returns
    // (broken pipe, connection reset). That is a closed connection, not an
    // error to report, so it must not reach the zone as an uncaught error.
    unawaited(socket.done.then<void>((_) {}, onError: (Object _) {}));
    final done = Completer<void>();
    final buffer = BytesBuilder(copy: false);
    var length = 0;
    var finished = false;
    var gotRequest = false;
    var clientGone = false;
    Timer? timer;
    StreamSubscription<Uint8List>? sub;

    void end() {
      if (done.isCompleted) return;
      timer?.cancel();
      done.complete();
    }

    // Stops reading and answers with [response] (null: just drops the client).
    Future<void> reply(AiLinkResponse? response) async {
      if (finished) return;
      finished = true;
      timer?.cancel();
      await sub?.cancel();
      if (response != null) {
        try {
          socket.add(utf8.encode('${response.encode()}\n'));
          await socket.flush();
        } on Object {
          // The client went away.
        }
      }
      end();
    }

    timer = Timer(readTimeout, () => unawaited(reply(null)));
    try {
      socket.add(utf8.encode('${aiLinkGreeting(_nonce ?? '')}\n'));
    } on Object {
      socket.destroy();
      _open.remove(socket);
      return;
    }
    sub = socket.listen(
      (chunk) {
        if (finished || gotRequest) return;
        if (length == 0 && chunk.isNotEmpty && chunk.first != 0x7B) {
          unawaited(reply(null)); // not a request: drop it without a word
          return;
        }
        final newline = chunk.indexOf(0x0A);
        final take = newline < 0 ? chunk.length : newline;
        // Counted while reading: the newline is part of the limit.
        if (length + take + 1 > maxRequestBytes) {
          unawaited(reply(AiLinkResponse.error(AiLinkCode.badRequest, 'The request is too large.')));
          return;
        }
        buffer.add(Uint8List.sublistView(chunk, 0, take));
        length += take;
        if (newline >= 0) {
          gotRequest = true;
          timer?.cancel(); // reading is over; the answer may take a while
          unawaited(_handle(buffer.takeBytes(), reply, () => !clientGone));
        }
      },
      // The client closing or dropping the connection after its request is
      // told to the handler: it must not act for a client that has gone.
      onError: (Object _) {
        clientGone = true;
        if (!gotRequest) unawaited(reply(null));
      },
      onDone: () {
        clientGone = true;
        if (!gotRequest) unawaited(reply(null));
      },
      cancelOnError: false,
    );
    await done.future;
    socket.destroy();
    _open.remove(socket);
  }

  Future<void> _handle(
    Uint8List bytes,
    Future<void> Function(AiLinkResponse?) reply,
    bool Function() clientOpen,
  ) async {
    final AiLinkRequest? request;
    try {
      request = AiLinkRequest.parse(utf8.decode(bytes));
    } on FormatException {
      return reply(null); // not text: not this protocol
    }
    // Not ai-link/2 at all (an HTTP request, other JSON): no answer.
    if (request == null) return reply(null);
    // This protocol, but not a request the app can act on.
    if (request is AiLinkMalformed) {
      return reply(AiLinkResponse.error(AiLinkCode.badRequest, request.message));
    }
    AiLinkResponse response;
    try {
      response = await handler(request, clientOpen);
    } on Object catch (e) {
      // Only the type: an exception's text could hold request content.
      debugPrint('Noted: an AI request failed: ${e.runtimeType}');
      response = AiLinkResponse.error(AiLinkCode.saveFailed);
    }
    return reply(response);
  }
}
