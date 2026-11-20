import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/app/session_wiring.dart' show UnexpectedErrorReporter;
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/core/vault/vault_status.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/request_sign_out.dart';
import 'package:dzeroth/features/messages/domain/e2ee/encryption_device.dart';
import 'package:dzeroth/features/messages/presentation/e2ee/encryption_copy.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/widgets/draft_dialogs.dart';
import 'package:dzeroth/shared/widgets/primitives/app_dialog.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_drafts_repository.dart';
import '../../../support/fake_encryption_device.dart';
import '../../../support/tablet_modal_harness.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

/// The sign-out warning (Plan 5b Task 13): a user with a vault on this device
/// is told that signing out deletes the encrypted messages kept here. With no
/// device in the tree, or no vault, the flow is exactly the old one.
void main() {
  setUpAll(() => registerFallbackValue(const AuthSignOutRequested()));

  late _MockAuthBloc auth;
  late FakeDraftsRepository drafts;
  late List<Object> reported;

  setUp(() {
    reported = [];
    auth = _MockAuthBloc();
    when(() => auth.add(any())).thenReturn(null);
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(
        status: AuthStatus.authenticated,
        user: AppUser(
          uid: 'uid-1',
          email: 'a@example.com',
          emailVerified: true,
          isPasswordProvider: true,
        ),
      ),
    );
    drafts = FakeDraftsRepository();
  });

  void addDraft() => drafts.rows.add(
    ComposerDraft(
      id: 'a',
      uid: 'uid-1',
      text: 'unsent',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ),
  );

  Widget Function(Widget) providers({
    Object? device = _absent,
    bool withDrafts = true,
    bool withReporter = false,
  }) => (app) {
    Widget child = BlocProvider<AuthBloc>.value(value: auth, child: app);
    if (withReporter) {
      child = RepositoryProvider<UnexpectedErrorReporter>.value(
        value: (error, stack) => reported.add(error),
        child: child,
      );
    }
    if (withDrafts) {
      child = RepositoryProvider<DraftsRepository>.value(
        value: drafts,
        child: child,
      );
    }
    if (!identical(device, _absent)) {
      child = RepositoryProvider<EncryptionDevice>.value(
        value: device as EncryptionDevice,
        child: child,
      );
    }
    return child;
  };

  Widget button(BuildContext context) => TextButton(
    key: const Key('sign-out'),
    onPressed: () => requestSignOut(context),
    child: const Text('Sign out'),
  );

  Future<void> tapSignOut(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
  }

  final warning = find.text(kSignOutVaultTitle);

  void expectSignedOut() =>
      verify(() => auth.add(const AuthSignOutRequested(uid: 'uid-1')))
          .called(1);

  void expectNoSignOut() => verifyNever(() => auth.add(any()));

  testWidgets('no EncryptionDevice in the tree: signs out at once as before', (
    tester,
  ) async {
    await pumpTabletModalHost(tester, wrap: providers(), trigger: button);
    await tapSignOut(tester);
    expect(warning, findsNothing);
    expectSignedOut();
  });

  testWidgets(
    'no EncryptionDevice and no DraftsRepository: signs out at once',
    (tester) async {
      await pumpTabletModalHost(
        tester,
        wrap: providers(withDrafts: false),
        trigger: button,
      );
      await tapSignOut(tester);
      expect(warning, findsNothing);
      expectSignedOut();
    },
  );

  for (final flag in E2eeFlag.values) {
    testWidgets('vaultKnown false, flag $flag: no dialog', (tester) async {
      await pumpTabletModalHost(
        tester,
        wrap: providers(
          device: FakeEncryptionDevice(vaultKnown: false, flag: flag),
        ),
        trigger: button,
      );
      await tapSignOut(tester);
      expect(warning, findsNothing);
      expectSignedOut();
    });
  }

  testWidgets('unsupported platform: no dialog', (tester) async {
    await pumpTabletModalHost(
      tester,
      wrap: providers(
        device: FakeEncryptionDevice(status: VaultStatus.unsupported),
      ),
      trigger: button,
    );
    await tapSignOut(tester);
    expect(warning, findsNothing);
    expectSignedOut();
  });

  for (final flag in E2eeFlag.values) {
    testWidgets(
      'vaultKnown true, flag $flag: the dialog shows the exact title and '
      'message; Cancel leaves the user signed in and adds no event',
      (tester) async {
        await pumpTabletModalHost(
          tester,
          wrap: providers(device: FakeEncryptionDevice(flag: flag)),
          trigger: button,
        );
        await tapSignOut(tester);

        expect(warning, findsOneWidget);
        expect(find.text(kSignOutVaultMessage), findsOneWidget);
        expect(find.text(kSignOutVaultLabel), findsWidgets);
        expectNoSignOut();

        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(warning, findsNothing);
        expectNoSignOut();
      },
    );
  }

  testWidgets('Escape cancels: no event', (tester) async {
    await pumpTabletModalHost(
      tester,
      wrap: providers(device: FakeEncryptionDevice()),
      trigger: button,
    );
    await tapSignOut(tester);
    expect(warning, findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(warning, findsNothing);
    expectNoSignOut();

    // Cancelled, so the latch is released: asking again shows it again.
    await tapSignOut(tester);
    expect(warning, findsOneWidget);
  });

  testWidgets('confirm with no unsent posts adds AuthSignOutRequested with the '
      'captured uid', (tester) async {
    await pumpTabletModalHost(
      tester,
      wrap: providers(device: FakeEncryptionDevice()),
      trigger: button,
    );
    await tapSignOut(tester);

    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text(kSignOutVaultLabel),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SignOutDraftsDialog), findsNothing);
    expectSignedOut();
  });

  testWidgets('confirm without a DraftsRepository signs out', (tester) async {
    await pumpTabletModalHost(
      tester,
      wrap: providers(device: FakeEncryptionDevice(), withDrafts: false),
      trigger: button,
    );
    await tapSignOut(tester);
    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text(kSignOutVaultLabel),
      ),
    );
    await tester.pumpAndSettle();
    expectSignedOut();
  });

  testWidgets('confirm with unsent posts then shows the drafts dialog', (
    tester,
  ) async {
    addDraft();
    await pumpTabletModalHost(
      tester,
      wrap: providers(device: FakeEncryptionDevice()),
      trigger: button,
    );
    await tapSignOut(tester);
    expect(find.byType(SignOutDraftsDialog), findsNothing);

    await tester.tap(
      find.descendant(
        of: find.byType(Dialog),
        matching: find.text(kSignOutVaultLabel),
      ),
    );
    await tester.pumpAndSettle();
    expect(warning, findsNothing);
    expect(find.byType(SignOutDraftsDialog), findsOneWidget);
    expectNoSignOut();

    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expectSignedOut();
    expect(drafts.wiped, isEmpty);
  });

  testWidgets('cancelling the warning with unsent posts never reaches the '
      'drafts dialog', (tester) async {
    addDraft();
    await pumpTabletModalHost(
      tester,
      wrap: providers(device: FakeEncryptionDevice()),
      trigger: button,
    );
    await tapSignOut(tester);
    expect(warning, findsOneWidget);
    expect(find.byType(SignOutDraftsDialog), findsNothing);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(SignOutDraftsDialog), findsNothing);
    expectNoSignOut();
    expect(drafts.wiped, isEmpty);
  });

  testWidgets('a second tap while the dialog is up opens no second dialog', (
    tester,
  ) async {
    late BuildContext captured;
    await pumpTabletModalHost(
      tester,
      wrap: providers(device: FakeEncryptionDevice()),
      trigger: (context) {
        captured = context;
        return button(context);
      },
    );
    requestSignOut(captured);
    requestSignOut(captured);
    await tester.pumpAndSettle();
    expect(find.byType(AppConfirmDialog), findsOneWidget);
    expect(warning, findsOneWidget);
  });

  // (A create that throws cannot be disposed by the provider package, so the
  // failure is in the device's own getter, read through a lazy create.)
  testWidgets('a provider that throws signs out', (tester) async {
    await pumpTabletModalHost(
      tester,
      wrap: (app) => RepositoryProvider<EncryptionDevice>(
        create: (_) => _ThrowingStatusDevice(),
        child: providers()(app),
      ),
      trigger: button,
    );
    await tapSignOut(tester);
    expect(warning, findsNothing);
    expectSignedOut();
  });

  testWidgets('a device whose vaultKnown throws signs out', (tester) async {
    await pumpTabletModalHost(
      tester,
      wrap: providers(device: _ThrowingDevice()),
      trigger: button,
    );
    await tapSignOut(tester);
    expect(warning, findsNothing);
    expectSignedOut();
  });

  testWidgets('nobody signed in: signs out at once, no device read', (
    tester,
  ) async {
    whenListen(
      auth,
      const Stream<AuthState>.empty(),
      initialState: const AuthState(),
    );
    final device = _FailOnReadDevice();
    await pumpTabletModalHost(
      tester,
      wrap: providers(device: device),
      trigger: button,
    );
    await tapSignOut(tester);
    expect(warning, findsNothing);
    verify(() => auth.add(const AuthSignOutRequested())).called(1);
    expect(device.reads, isEmpty);
  });

  testWidgets('a warning that cannot be shown leaves the user signed in and '
      'the next tap warns again', (tester) async {
    // No MaterialLocalizations above the navigator: showDialog throws.
    await tester.pumpWidget(
      providers(device: FakeEncryptionDevice(), withReporter: true)(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Navigator(
            onGenerateRoute: (_) => PageRouteBuilder<void>(
              pageBuilder: (context, _, _) => Center(
                child: GestureDetector(
                  key: const Key('sign-out'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () => requestSignOut(context),
                  child: const SizedBox(width: 100, height: 40),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    expectNoSignOut();
    expect(reported, hasLength(1));
    expect(
      reported.single.toString(),
      StateError('Sign-out warning could not be shown.').toString(),
    );

    // The latch is released: a working tree warns on the next tap.
    await pumpTabletModalHost(
      tester,
      wrap: providers(device: FakeEncryptionDevice(), withReporter: true),
      trigger: button,
    );
    await tapSignOut(tester);
    expect(warning, findsOneWidget);
    expectNoSignOut();
  });

  for (final flag in E2eeFlag.values) {
    testWidgets('confirm adds exactly one AuthSignOutRequested, flag $flag', (
      tester,
    ) async {
      await pumpTabletModalHost(
        tester,
        wrap: providers(device: FakeEncryptionDevice(flag: flag)),
        trigger: button,
      );
      await tapSignOut(tester);
      await tester.tap(
        find.descendant(
          of: find.byType(Dialog),
          matching: find.text(kSignOutVaultLabel),
        ),
      );
      await tester.pumpAndSettle();
      final events = verify(() => auth.add(captureAny())).captured;
      expect(events, [const AuthSignOutRequested(uid: 'uid-1')]);
    });
  }

  for (final status in [
    VaultStatus.opening,
    VaultStatus.unavailable,
    VaultStatus.keyLost,
    VaultStatus.storageChanged,
    VaultStatus.heldElsewhere,
  ]) {
    testWidgets('vaultKnown true, status $status: the warning shows', (
      tester,
    ) async {
      await pumpTabletModalHost(
        tester,
        wrap: providers(device: FakeEncryptionDevice(status: status)),
        trigger: button,
      );
      await tapSignOut(tester);
      expect(warning, findsOneWidget);
      expectNoSignOut();
    });
  }

  // Three widths: phone, tablet (beside the rail) and desktop (the feed
  // column), the alert width, never wider than 400.
  for (final width in [390.0, 834.0, 1440.0]) {
    testWidgets('${width.toInt()} dp: the warning is at the alert width and '
        'centred where the drafts dialog is', (tester) async {
      await pumpTabletModalHost(
        tester,
        width: width,
        wrap: providers(device: FakeEncryptionDevice()),
        trigger: button,
      );
      await tapSignOut(tester);

      expect(warning, findsOneWidget);
      expect(tester.takeException(), isNull);
      final box = openDialogRect(tester);
      expect(box.width, lessThanOrEqualTo(AppSize.alertDialogMax + 0.5));
      if (width == 834) {
        final content = tabletContentRect(Size(width, 1194));
        expect(box.center.dx, closeTo(content.center.dx, 1));
      } else if (width == 1440) {
        final column = desktopColumnRect(tester, Size(width, 1194));
        expect(box.center.dx, closeTo(column.center.dx, 1));
      } else {
        expect(box.center.dx, closeTo(width / 2, 1));
      }
    });
  }
}

const Object _absent = Object();

/// A device whose every getter fails the test: nobody signed in never reads it.
/// The production code may swallow the throw, so reads are also recorded.
class _FailOnReadDevice implements EncryptionDevice {
  final List<Symbol> reads = [];

  @override
  dynamic noSuchMethod(Invocation invocation) {
    reads.add(invocation.memberName);
    throw TestFailure('the device was read: ${invocation.memberName}');
  }
}

class _ThrowingStatusDevice extends FakeEncryptionDevice {
  @override
  CountingNotifier<VaultStatus> get vaultStatus =>
      throw StateError('status read failed');
}

class _ThrowingDevice extends FakeEncryptionDevice {
  @override
  bool get vaultKnown => throw StateError('vault read failed');
}
