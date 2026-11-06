// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:noted_auth/noted_auth.dart';

/// The OS keychain or keystore (flutter_secure_storage) as the [TokenStore].
///
/// - Android: its shared preferences are left out of auto-backup and device
///   transfer (`backup_rules.xml`, `data_extraction_rules.xml`).
/// - iOS: items are this-device-only, so they never reach iCloud Keychain or
///   a backup restored on another device; a reinstall's leftovers are removed
///   by [clearKeychainOnFirstLaunch].
/// - macOS: the file-based keychain, because the data-protection keychain needs
///   a keychain-access-groups entitlement, which needs a signing team.
class SecureTokenStore implements TokenStore {
  SecureTokenStore([FlutterSecureStorage? storage])
    : _storage = storage ?? _default;

  static const FlutterSecureStorage _default = FlutterSecureStorage(
    iOptions: IOSOptions(
      accessibility: KeychainAccessibility.first_unlock_this_device,
    ),
    mOptions: MacOsOptions(usesDataProtectionKeychain: false),
  );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);

  /// Deletes every item Noted has in the keychain.
  static Future<void> deleteEverything() => _default.deleteAll();
}
