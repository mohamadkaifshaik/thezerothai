import 'dart:io';

import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:flutter_test/flutter_test.dart';

const _copyPath =
    'lib/features/messages/presentation/e2ee/encryption_copy.dart';

/// Joins adjacent string literals (`'a' 'b'`, also across lines and mixed
/// quote kinds) so a phrase split over two literals is still found.
String joinAdjacentLiterals(String source) =>
    source.replaceAll(RegExp(r'''['"]\s+['"]'''), '');

/// The source without comment lines, so only string literals and code remain.
String _codeOnly([String path = _copyPath]) => joinAdjacentLiterals(
  File(path)
      .readAsLinesSync()
      .where((l) => !l.trimLeft().startsWith('//'))
      .join('\n')
      .toLowerCase(),
);

void main() {
  test('the normaliser joins a phrase split over two literals', () {
    final split = joinAdjacentLiterals("'Nobody can '\n    \"read this\"");
    expect(split.toLowerCase().contains('nobody can read'), isTrue);
  });

  test('the fixed strings are verbatim', () {
    expect(kLineEncryptionReset, 'Encryption was reset');
    expect(kLineUnknownDevice, 'An unknown device was added');
    expect(kStateListUnverifiableTitle, "The device list can't be checked");
    expect(kCouldNotDecryptText, "Couldn't decrypt this message");
    expect(kCouldNotVerifyText, "This message couldn't be verified");
    expect(
      kNotOnThisDeviceText,
      "Encrypted messages aren't available on this device yet.",
    );
    expect(kStatePeerNoDeviceText, "They can't receive encrypted messages yet");
    expect(kStatusRemovedTitle, 'This device was removed');
    expect(
      kResetNoRestartWarning,
      'You will not be able to use encrypted messages on this device '
      'afterwards',
    );
    expect(
      kDeviceRemoveMessage,
      endsWith(
        'Until each conversation has been updated, that device may still '
        'receive and send messages.',
      ),
    );
  });

  test('no string overclaims', () {
    final source =
        _codeOnly() +
        _codeOnly(
          'lib/features/messages/presentation/e2ee/'
          'encryption_error_messages.dart',
        );
    for (final banned in [
      'is verified',
      'verified contact',
      'marked verified',
      'secure chat',
      'nobody can read',
      'no one can read',
      'recover',
      'qr',
      'stops receiving at once',
    ]) {
      expect(source.contains(banned), isFalse, reason: banned);
    }
  });

  test('the help text carries the honest limit', () {
    expect(
      kEncryptionHelp2,
      contains('recognises every device listed as your own'),
    );
    expect(kEncryptionHelp2, contains('compromised server'));
    expect(kEncryptionHelp8, contains('reorder'));
    expect(kEncryptionHelp5, contains('can take days'));
    expect(kEncryptionHelp5, contains('blocked'));
    expect(kEncryptionHelp5, contains("haven't been accepted"));
    expect(kEncryptionHelp10, isNotEmpty);
    expect(kReportEncryptedDetail, contains('kept with the report'));
  });

  test('the device-change sentence is qualified', () {
    expect(
      kEncryptionHelp3,
      contains('on devices that are already part of it'),
    );
    expect(kEncryptionHelp3, contains("request you haven't accepted"));
    expect(_codeOnly().contains('removed automatically'), isFalse);
  });

  test('name fallbacks', () {
    expect(
      lineDeviceAddedTheirs('Ada'),
      'Ada has a new device in this conversation',
    );
    expect(
      lineDeviceAddedTheirs(''),
      'They have a new device in this conversation',
    );
    expect(
      lineDeviceRemovedTheirs('Ada'),
      'A device of Ada was removed from this conversation',
    );
    expect(
      lineDeviceRemovedTheirs(''),
      'One of their devices was removed from this conversation',
    );
    expect(
      securityCodeIntro('Ada'),
      'Compare these numbers with Ada, in person or on a call you trust.',
    );
    expect(
      securityCodeIntro(''),
      'Compare these numbers with the other person, in person or on a call '
      'you trust.',
    );
    expect(deviceRemoveLabel('Nov 3'), 'Remove device added Nov 3');
    expect(deviceRemoveLabel(''), 'Remove device');
  });

  test('removalsPendingText(1) is the singular, (12) the plural', () {
    expect(removalsPendingText(1), '1 conversation still to update');
    expect(removalsPendingText(12), '12 conversations still to update');
  });

  test('counts and spoken labels', () {
    expect(devicesCount(3), '3 of 5 devices');
    expect(securityCodeGroupLabel(1, '01234'), 'Group 1 of 12: 0 1 2 3 4');
    expect(securityCodeMine(2), 'Your devices in this conversation: 2');
    expect(securityCodeTheirs(1), 'Their devices in this conversation: 1');
    expect(deviceAddedTitle('Nov 3'), 'Device added Nov 3');
    expect(deviceAddedSubtitle('Nov 3'), 'Added Nov 3');
    expect(deviceLastActive('2 days ago'), 'Last active 2 days ago');
  });
}
