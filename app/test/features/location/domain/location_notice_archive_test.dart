import 'package:dzeroth/features/location/domain/location_copy.dart';
import 'package:flutter_test/flutter_test.dart';

/// Every version of the Location consent notice, word for word. The server
/// stores only the version number with a consent, so this archive is the
/// evidence of what each version said. Never edit or delete an entry: to
/// change the wording, bump [kLocationConsentCopyVersion] (and the server's
/// LOCATION_CONSENT_COPY_VERSION / LOCATION_CONSENT_MIN_COPY_VERSION defaults)
/// and add a new entry.
const _archive = <int, List<String>>{
  1: [
    'What is stored: the one area you pick (a neighbourhood or a city), the '
        'time you agreed and the version of this text. No coordinates, no '
        'device location.',
    'Why: so plans in or near your area can be shown to you.',
    'Who sees it: only you. A plan shows the area its organiser chose for '
        'the plan, never where you live.',
    'Withdraw any time: Settings > Location > Clear my area removes it at '
        'once.',
    'I am 18 or older',
    'Continue',
  ],
  2: [
    'What is stored: the one area you pick (a neighbourhood or a city); that '
        'you confirmed you are 18 or older, and when; the time you agreed and '
        'the version of this text; and a record of each time you agree or '
        'withdraw, which we keep until you delete your account. No '
        'coordinates, no device location.',
    'Why: so plans in or near your area can be shown to you.',
    'Who sees it: no other user. Your area is not shown on your profile or to '
        'anyone you follow. It is kept in our database, which Google Cloud '
        'runs for us, and a backup can hold a copy for up to 14 days after you '
        'clear it.',
    'Plans: if you organise a plan you can give it an area. That area belongs '
        'to the plan, not to you. Everyone who can see the plan sees it, it '
        'shows in Nearby, and it stays until you delete the plan or your '
        'account. Pick where the plan meets, never where you live.',
    'Withdraw any time: Settings > Location > Clear my area removes your area '
        'at once. We keep a record that you withdrew until you delete your '
        'account. Clearing it does not change the area of a plan you '
        'organised.',
    'I am 18 or older',
    'Agree and continue',
  ],
};

void main() {
  test('the current notice text is archived under its version', () {
    final current = [
      kLocationRationaleStored,
      kLocationRationaleWhy,
      kLocationRationaleWho,
      kLocationRationalePlans,
      kLocationRationaleWithdraw,
      kLocationAdultTick,
      kLocationContinue,
    ];
    expect(
      _archive[kLocationConsentCopyVersion],
      current,
      reason:
          'The consent notice changed without a version bump (or the new '
          'version is not archived). Bump kLocationConsentCopyVersion, add '
          'the new text to _archive and keep the old entries.',
    );
  });

  test('archive versions are consecutive from the first archived one', () {
    final versions = _archive.keys.toList()..sort();
    for (var i = 1; i < versions.length; i++) {
      expect(versions[i], versions[i - 1] + 1);
    }
    expect(versions.last, kLocationConsentCopyVersion);
  });
}
