import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';

/// Platforms with neither dart:io nor JS interop have no vault.
Future<VaultCipher> openPlatformVaultCipher({
  required String uid,
  required CryptoEngine engine,
}) => throw UnsupportedError('No encrypted vault on this platform.');
