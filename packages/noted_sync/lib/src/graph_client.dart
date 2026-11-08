// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'clock.dart';
import 'remote_item.dart';
import 'types.dart';

/// Gives the access token; [forceRefresh] asks for a fresh one after a 401.
/// Throws [SignedOutException] when the user has to sign in again.
typedef TokenCallback = Future<String> Function({bool forceRefresh});

/// The token callback has no usable token: the user must sign in again.
class SignedOutException implements Exception {
  const SignedOutException([this.message = 'Signed out']);
  final String message;
  @override
  String toString() => 'SignedOutException: $message';
}

class GraphException implements Exception {
  GraphException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;

  /// Graph's error code, when the body had one.
  final String? code;
  @override
  String toString() =>
      'GraphException($statusCode${code == null ? '' : ' $code'}): $message';
}

/// The call didn't get an answer (connection, timeout, bad reply). The message
/// never carries an address: links can hold a pre-authorised token.
class GraphTransportException extends GraphException {
  GraphTransportException(Object cause)
    : super('Network problem (${cause.runtimeType})');
}

class GraphNotFound extends GraphException {
  GraphNotFound(super.message) : super(statusCode: 404);
}

/// A link (next page, delta link, redirect target) that is not on the Graph
/// origin, or a redirect that isn't allowed. The token is never sent there.
class GraphRefusedLink extends GraphException {
  GraphRefusedLink(super.message);
}

/// The call is not supported on this kind of item or account.
class GraphNotSupported extends GraphException {
  GraphNotSupported(super.message, {super.statusCode, super.code});
}

/// 410: the delta token is no longer good. [location] restarts the listing.
class GraphGone extends GraphException {
  GraphGone(super.message, {this.location, this.uploadDifferences = false})
    : super(statusCode: 410);

  final Uri? location;

  /// `resyncChangesUploadDifferences` (else `resyncChangesApplyDifferences`).
  final bool uploadDifferences;
}

class GraphUnauthorized extends GraphException {
  GraphUnauthorized(super.message) : super(statusCode: 401);
}

class GraphThrottled extends GraphException {
  GraphThrottled(super.message) : super(statusCode: 429);
}

/// Microsoft Graph, the few calls the pull needs.
///
/// - The access token goes only to [origin] (Graph itself; the fake server in
///   tests). Next links, delta links and a 410's `Location` on another origin
///   are refused.
/// - Redirects (downloads) are followed by hand: https only, except the
///   configured origin, at most [maxRedirects] hops, and no `Authorization`
///   on a redirected request.
/// - At most [maxInFlight] requests at once. On 429 and 503 every request
///   waits for `Retry-After`; without it, 2 s doubling up to 5 min.
/// - A 401 asks the token callback once for a fresh token and retries.
class GraphClient {
  GraphClient({
    required this.token,
    Uri? origin,
    http.Client? client,
    Clock? clock,
    this.maxInFlight = 4,
    this.maxRedirects = 5,
    this.maxThrottleRetries = 8,
    this.timeout = const Duration(seconds: 60),
  }) : origin = origin ?? Uri.parse('https://graph.microsoft.com'),
       _client = client ?? http.Client(),
       _clock = clock ?? const SystemClock();

  /// Scheme, host and port of Graph.
  final Uri origin;
  final int maxInFlight;
  final int maxRedirects;
  final int maxThrottleRetries;
  final Duration timeout;

  final TokenCallback token;
  final http.Client _client;
  final Clock _clock;

  static const Duration _firstBackoff = Duration(seconds: 2);
  static const Duration _maxBackoff = Duration(minutes: 5);

  int _inFlight = 0;
  final List<Completer<void>> _slotWaiters = [];
  DateTime? _pausedUntil;
  Duration? _backoff;

  void close() => _client.close();

  // --- Calls ---------------------------------------------------------------

  Uri _api(List<String> segments, [Map<String, String>? query]) => origin
      .replace(pathSegments: ['v1.0', ...segments], queryParameters: query);

  List<String> _drive(String? driveId) =>
      driveId == null ? ['me', 'drive'] : ['drives', driveId];

  Future<RemoteItem> getItem(String driveId, String itemId) async =>
      RemoteItem.fromJson(
        await _getJson(_api([..._drive(driveId), 'items', itemId])),
      );

  /// First page of a delta listing of [itemId]'s folder, or of the whole drive
  /// when [itemId] is null. Throws [GraphNotSupported] when the folder form
  /// isn't available (400 or 501 with a not-supported code).
  Future<DeltaPage> deltaStart(String driveId, String? itemId) {
    final uri = itemId == null
        ? _api([..._drive(driveId), 'root', 'delta'])
        : _api([..._drive(driveId), 'items', itemId, 'delta']);
    return deltaAt(uri);
  }

  /// A delta page at [link] (a next link, a delta link, a 410's `Location`).
  Future<DeltaPage> deltaAt(Uri link) async {
    final json = await _getJson(checkLink(link));
    final items = <RemoteItem>[];
    for (final v in (json['value'] as List?) ?? const []) {
      if (v is Map<String, dynamic> && v['id'] is String) {
        items.add(RemoteItem.fromJson(v));
      }
    }
    return DeltaPage(
      items,
      nextLink: _linkOf(json['@odata.nextLink']),
      deltaLink: _linkOf(json['@odata.deltaLink']),
    );
  }

  Uri? _linkOf(Object? v) {
    if (v is! String) return null;
    final Uri u;
    try {
      u = Uri.parse(v);
    } on FormatException {
      throw GraphRefusedLink('A link was not a valid address');
    }
    return checkLink(u);
  }

  /// [link] itself when it is on the Graph origin, else throws
  /// [GraphRefusedLink].
  Uri checkLink(Uri link) {
    if (!_sameOrigin(link)) {
      throw GraphRefusedLink('A link on another origin was refused');
    }
    return link;
  }

  bool _sameOrigin(Uri u) =>
      u.hasScheme &&
      u.scheme == origin.scheme &&
      u.host == origin.host &&
      u.port == origin.port;

  /// Every child of a folder, following the pages.
  Future<List<RemoteItem>> children(String? driveId, String itemId) =>
      _childrenAt(
        _api(
          [..._drive(driveId), 'items', itemId, 'children'],
          {r'$top': '200'},
        ),
      );

  Future<List<RemoteItem>> _childrenAt(Uri first) async {
    final out = <RemoteItem>[];
    Uri? next = first;
    var pages = 0;
    while (next != null) {
      if (++pages > 10000) throw GraphException('Too many pages');
      final json = await _getJson(next);
      for (final v in (json['value'] as List?) ?? const []) {
        if (v is Map<String, dynamic> && v['id'] is String) {
          out.add(RemoteItem.fromJson(v));
        }
      }
      next = _linkOf(json['@odata.nextLink']);
    }
    return out;
  }

  /// The folders in [parentItemId] (the drive's root when null), by name.
  Future<List<RemoteItem>> listFolders({
    String? parentItemId,
    String? driveId,
  }) async {
    final uri = parentItemId == null
        ? _api([..._drive(driveId), 'root', 'children'], {r'$top': '200'})
        : _api(
            [..._drive(driveId), 'items', parentItemId, 'children'],
            {r'$top': '200'},
          );
    final all = await _childrenAt(uri);
    return [
      for (final i in all)
        if (i.isFolder && !i.deleted) i,
    ]..sort(
      (a, b) =>
          (a.name ?? '').toLowerCase().compareTo((b.name ?? '').toLowerCase()),
    );
  }

  /// What Noted would find in the folder [itemId].
  Future<FolderHint> folderHint(String itemId, {String? driveId}) async {
    final kids = await children(driveId, itemId);
    var canvases = 0;
    var holds = false;
    final subfolders = <RemoteItem>[];
    for (final k in kids) {
      final n = (k.name ?? '').toLowerCase();
      if (k.isFolder) {
        subfolders.add(k);
      } else if (n.endsWith('.canvas')) {
        canvases++;
      } else if (n == 'noted-binder.json') {
        holds = true;
      }
    }
    final flags = await Future.wait([
      for (final f in subfolders) holdsBinderFile(f.id, driveId: driveId),
    ]);
    return FolderHint(
      canvasCount: canvases,
      binderCount: flags.where((b) => b).length,
      holdsBinderFile: holds,
    );
  }

  /// Whether the folder [itemId] holds a file named `noted-binder.json`.
  Future<bool> holdsBinderFile(String itemId, {String? driveId}) async {
    final kids = await children(driveId, itemId);
    return kids.any(
      (k) => !k.isFolder && (k.name ?? '').toLowerCase() == 'noted-binder.json',
    );
  }

  /// Downloads the content of [itemId] into [dest] (written fresh). The
  /// redirect to the storage host is followed by hand, without the token.
  Future<void> download(String driveId, String itemId, File dest) async {
    var uri = _api([..._drive(driveId), 'items', itemId, 'content']);
    var auth = true;
    for (var hop = 0; hop <= maxRedirects; hop++) {
      final current = uri;
      final next = await _call<Uri?>(
        current,
        auth: auth,
        onResponse: (r) async {
          if (r.statusCode >= 300 && r.statusCode < 400) {
            final loc = r.headers['location'];
            await _drain(r);
            if (loc == null) {
              throw GraphException('Redirect without a Location');
            }
            try {
              return current.resolve(loc);
            } on FormatException {
              throw GraphRefusedLink('A redirect was not a valid address');
            }
          }
          if (r.statusCode != 200) {
            throw _error(r.statusCode, await _bytes(r), r.headers);
          }
          final sink = dest.openWrite();
          try {
            await sink.addStream(r.stream.timeout(timeout));
            await sink.flush();
          } finally {
            await sink.close();
          }
          return null;
        },
      );
      if (next == null) return;
      if (!(next.scheme == 'https' || _sameOrigin(next))) {
        throw GraphRefusedLink('A redirect to a non-https address was refused');
      }
      uri = next;
      auth = false;
    }
    throw GraphRefusedLink('Too many redirects');
  }

  // --- Plumbing ------------------------------------------------------------

  Future<Map<String, dynamic>> _getJson(Uri uri) => _call<Map<String, dynamic>>(
    uri,
    onResponse: (r) async {
      final body = await _bytes(r);
      if (r.statusCode != 200) {
        throw _error(r.statusCode, body, r.headers);
      }
      final j = jsonDecode(utf8.decode(body));
      if (j is! Map<String, dynamic>) {
        throw GraphException('Unexpected reply');
      }
      return j;
    },
  );

  Future<List<int>> _bytes(http.StreamedResponse r) async {
    final b = <int>[];
    await for (final c in r.stream.timeout(timeout)) {
      b.addAll(c);
    }
    return b;
  }

  Future<void> _drain(http.StreamedResponse r) async {
    try {
      await r.stream.drain<void>().timeout(timeout);
    } catch (_) {
      // Only draining.
    }
  }

  GraphException _error(
    int status,
    List<int> body,
    Map<String, String> headers,
  ) {
    String? code;
    String? inner;
    var message = 'HTTP $status';
    try {
      final j = jsonDecode(utf8.decode(body, allowMalformed: true));
      final e = j is Map ? j['error'] : null;
      if (e is Map) {
        code = e['code'] is String ? e['code'] as String : null;
        final i = e['innerError'];
        inner = i is Map && i['code'] is String ? i['code'] as String : null;
        if (e['message'] is String) message = e['message'] as String;
      }
    } catch (_) {
      // No JSON body.
    }
    final codes = '${code ?? ''} ${inner ?? ''}';
    if (status == 404) return GraphNotFound(message);
    if (status == 410) {
      final loc = headers['location'];
      Uri? location;
      if (loc != null) {
        final u = Uri.tryParse(loc);
        if (u == null || !_sameOrigin(u)) {
          return GraphRefusedLink(
            'A resync link on another origin was refused',
          );
        }
        location = u;
      }
      return GraphGone(
        message,
        location: location,
        uploadDifferences: codes.contains('resyncChangesUploadDifferences'),
      );
    }
    if ((status == 400 || status == 501) &&
        codes.toLowerCase().contains('notsupported')) {
      return GraphNotSupported(message, statusCode: status, code: code);
    }
    return GraphException(message, statusCode: status, code: code);
  }

  /// One request through the gate: waits out a pause, takes a slot, attaches
  /// the token on the Graph origin only, retries after 429 and 503 and once
  /// after 401.
  Future<T> _call<T>(
    Uri uri, {
    bool auth = true,
    required Future<T> Function(http.StreamedResponse r) onResponse,
  }) async {
    var refreshed = false;
    for (var attempt = 0; ; attempt++) {
      await _enter();
      try {
        final req = http.Request('GET', uri)..followRedirects = false;
        final withToken = auth && _sameOrigin(uri);
        if (withToken) {
          final t = await token(forceRefresh: refreshed);
          req.headers['Authorization'] = 'Bearer $t';
        }
        final r = await _client.send(req).timeout(timeout);
        if (r.statusCode == 429 || r.statusCode == 503) {
          await _drain(r);
          if (attempt >= maxThrottleRetries) {
            throw GraphThrottled('Still throttled after $attempt retries');
          }
          _pause(_retryAfter(r.headers['retry-after']));
          continue;
        }
        if (r.statusCode == 401 && withToken) {
          await _drain(r);
          if (refreshed) throw GraphUnauthorized('Unauthorized');
          refreshed = true;
          continue;
        }
        _backoff = null;
        return await onResponse(r);
      } on GraphException {
        rethrow;
      } on SignedOutException {
        rethrow;
      } on FileSystemException {
        rethrow;
      } on Exception catch (e) {
        // A client or socket error carries the address it was talking to.
        throw GraphTransportException(e);
      } finally {
        _leave();
      }
    }
  }

  Duration? _retryAfter(String? v) {
    if (v == null) return null;
    final s = int.tryParse(v.trim());
    if (s != null) return Duration(seconds: s < 0 ? 0 : s);
    try {
      final d = HttpDate.parse(v).difference(_clock.now().toUtc());
      return d.isNegative ? Duration.zero : d;
    } catch (_) {
      return null;
    }
  }

  /// All requests wait: for [wait], or the next step of the back-off.
  void _pause(Duration? wait) {
    final Duration d;
    if (wait != null) {
      d = wait;
    } else {
      final doubled = _backoff == null ? _firstBackoff : _backoff! * 2;
      _backoff = doubled > _maxBackoff ? _maxBackoff : doubled;
      d = _backoff!;
    }
    final until = _clock.now().add(d);
    if (_pausedUntil == null || until.isAfter(_pausedUntil!)) {
      _pausedUntil = until;
    }
  }

  Future<void> _waitPause() async {
    while (true) {
      final until = _pausedUntil;
      if (until == null) return;
      final left = until.difference(_clock.now());
      if (left <= Duration.zero) {
        _pausedUntil = null;
        return;
      }
      await _clock.delay(left);
    }
  }

  Future<void> _enter() async {
    while (true) {
      await _waitPause();
      if (_inFlight >= maxInFlight) {
        final c = Completer<void>();
        _slotWaiters.add(c);
        await c.future;
        continue;
      }
      _inFlight++;
      // A pause may have started while this waited; it applies to all.
      final until = _pausedUntil;
      if (until != null && until.isAfter(_clock.now())) {
        _leave();
        continue;
      }
      return;
    }
  }

  void _leave() {
    _inFlight--;
    if (_slotWaiters.isNotEmpty) _slotWaiters.removeAt(0).complete();
  }
}
