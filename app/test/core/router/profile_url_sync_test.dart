import 'package:dzeroth/core/router/profile_url_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late List<Uri> calls;
  late ProfileUrlSync sync;
  setUp(() {
    calls = [];
    sync = ProfileUrlSync(replacer: calls.add);
  });

  test('replaces /u/<uid> with the handle form for the same user', () {
    expect(
      sync.showHandle(requestedUserId: 'u1', loadedUserId: 'u1', handle: 'ann'),
      isTrue,
    );
    expect(calls.single.toString(), '/profile/ann');
  });

  test('ignores another user, empty handle and empty request', () {
    expect(
      sync.showHandle(requestedUserId: 'u1', loadedUserId: 'u2', handle: 'ann'),
      isFalse,
    );
    expect(
      sync.showHandle(requestedUserId: 'u1', loadedUserId: 'u1', handle: ' '),
      isFalse,
    );
    expect(
      sync.showHandle(requestedUserId: '', loadedUserId: '', handle: 'ann'),
      isFalse,
    );
    expect(calls, isEmpty);
  });

  test('encodes the handle and drops a leading @', () {
    expect(
      ProfileUrlSync.handleUri('@a b/c')!.toString(),
      '/profile/a%20b%2Fc',
    );
    expect(ProfileUrlSync.handleUri('@'), isNull);
  });

  test('default replacer is a no-op off the web', () {
    expect(() => replaceBrowserUrl(Uri(path: '/profile/x')), returnsNormally);
  });
}
