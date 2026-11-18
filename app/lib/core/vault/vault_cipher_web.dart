import 'package:dzeroth/core/crypto/crypto_engine.dart';
import 'package:dzeroth/core/vault/vault_cipher.dart';

/// Placeholder: the web vault key (a non-extractable WebCrypto key) replaces
/// this body in a later task. Until then the web has no vault.
Future<VaultCipher> openPlatformVaultCipher({
  required String uid,
  required CryptoEngine engine,
}) => throw UnsupportedError('The web vault is not built yet.');
