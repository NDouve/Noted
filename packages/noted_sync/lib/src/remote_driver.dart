// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'dart:io';

import 'journal.dart';
import 'remote_item.dart';
import 'types.dart';

/// The sign-in callback has no usable credential: the user must sign in again.
class SignedOutException implements Exception {
  const SignedOutException([this.message = 'Signed out']);
  final String message;
  @override
  String toString() => 'SignedOutException: $message';
}

/// What went wrong talking to a remote store. The engine tests these base
/// classes only, so every driver's own errors are subtypes of them.
class RemoteException implements Exception {
  RemoteException(this.message, {this.statusCode, this.code});
  final String message;
  final int? statusCode;

  /// The provider's own error code, when the reply had one.
  final String? code;
  @override
  String toString() =>
      'RemoteException($statusCode${code == null ? '' : ' $code'}): $message';
}

/// The call didn't get an answer (connection, timeout, bad reply). The message
/// never carries an address: links can hold a pre-authorised token. Never
/// absence: a round that meets it applies nothing.
class RemoteTransport extends RemoteException {
  RemoteTransport(Object cause)
    : super('Network problem (${cause.runtimeType})');
}

class RemoteNotFound extends RemoteException {
  RemoteNotFound(super.message) : super(statusCode: 404);
}

/// The credential was refused (401): signed out.
class RemoteUnauthorized extends RemoteException {
  RemoteUnauthorized(super.message) : super(statusCode: 401);
}

class RemoteThrottled extends RemoteException {
  RemoteThrottled(super.message) : super(statusCode: 429);
}

/// The call is not supported on this kind of item or account.
class RemoteNotSupported extends RemoteException {
  RemoteNotSupported(super.message, {super.statusCode, super.code});
}

/// A refusal that is not absence: CORS, TLS, or a redirect or link on another
/// origin. The credential is never sent there.
class RemoteRefused extends RemoteException {
  RemoteRefused(super.message);
}

/// The item's version moved while it was being read (drivers without a server
/// hash only). Nothing is applied; the next round tries again.
class RemoteChanged extends RemoteException {
  RemoteChanged(super.message);
}

/// What a driver can do, as far as the engine cares.
class RemoteCaps {
  const RemoteCaps({required this.serverHash, required this.fullListing});

  /// The listing carries a content hash (quickXor) the engine can check a
  /// download and a local file against. Without one, [RemoteDriver.download]
  /// is version-checked and the engine compares content itself.
  final bool serverHash;

  /// Every fetch lists the whole tree (no cursor).
  final bool fullListing;
}

/// A restart of the listing the driver was told to apply (Graph's 410).
class RemoteResync {
  const RemoteResync({required this.uploadDifferences});

  /// A path missing remotely is kept and listed, never turned into a delete.
  final bool uploadDifferences;
}

/// A complete remote map. Never partial: a driver throws, or returns null for
/// a root that is gone.
class RemoteFetch {
  RemoteFetch({
    required this.map,
    required this.cursor,
    required this.endpoint,
    required this.seq,
    this.resync,
  });

  final Map<String, RemoteEntry> map;

  /// Where the next fetch starts (Graph's delta link).
  final String cursor;
  final String endpoint;
  final int seq;
  final RemoteResync? resync;
}

/// One remote store the pull engine reads from. Content-blind: it moves
/// listings and bytes only.
abstract class RemoteDriver {
  /// `onedrive`, `webdav`: a state folder name.
  String get provider;

  /// For messages: `OneDrive`, `WebDAV`.
  String get displayName;

  /// The id of the chosen root folder.
  String get rootId;

  RemoteCaps get caps;

  /// The root item; throws [RemoteNotFound] when it is gone.
  Future<RemoteItem> root();

  /// The whole remote map, folded from [map] and [cursor] (null: a first
  /// listing) and ending at [seq]; null when the root is gone.
  Future<RemoteFetch?> fetch(
    Map<String, RemoteEntry> map,
    String? cursor,
    String? endpoint,
    int seq,
  );

  Future<List<RemoteItem>> children(String itemId);

  Future<List<RemoteItem>> listFolders({String? parentItemId});

  Future<FolderHint> folderHint(String itemId);

  /// Writes the content of [entry] into [dest] (fresh). A driver without a
  /// server hash throws [RemoteChanged] when the version moved meanwhile.
  Future<void> download(RemoteEntry entry, File dest);
}
