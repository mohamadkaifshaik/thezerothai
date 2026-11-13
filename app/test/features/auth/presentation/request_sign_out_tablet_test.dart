import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/feature_flags/ui_shell_feature_flag.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/auth/domain/app_user.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_bloc.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_event.dart';
import 'package:dzeroth/features/auth/presentation/bloc/auth_state.dart';
import 'package:dzeroth/features/auth/presentation/request_sign_out.dart';
import 'package:dzeroth/features/posts/data/drafts_repository.dart';
import 'package:dzeroth/features/posts/domain/composer_draft.dart';
import 'package:dzeroth/features/posts/presentation/widgets/draft_dialogs.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import '../../../support/fake_drafts_repository.dart';
import '../../../support/tablet_modal_harness.dart';

class _MockAuthBloc extends MockBloc<AuthEvent, AuthState>
    implements AuthBloc {}

/// The "Sign out?" dialog of [requestSignOut] (unsent posts on the device)
/// opens from the root navigator's own context after an `await`. On the
/// tablet layout it is still centred on the content area beside the rail
/// (tablet plan section 5.4): the presentation is resolved at the button.
/// On the desktop layout (>= 1200 dp, D1) it is centred on the shell's feed
/// column. Phones and either flag off keep the window-centred dialog
/// (ruling R-1).
void main() {
  setUpAll(() => registerFallbackValue(const AuthSignOutRequested()));

  late _MockAuthBloc auth;
  late FakeDraftsRepository drafts;

  setUp(() {
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
    drafts = FakeDraftsRepository(
      drafts: [
        ComposerDraft(
          id: 'a',
          uid: 'uid-1',
          text: 'unsent',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ],
    );
  });

  Widget providers(Widget app) => RepositoryProvider<DraftsRepository>.value(
    value: drafts,
    child: BlocProvider<AuthBloc>.value(value: auth, child: app),
  );

  Widget button(BuildContext context) => TextButton(
    key: const Key('sign-out'),
    onPressed: () => requestSignOut(context),
    child: const Text('Sign out'),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.tap(find.byKey(const Key('sign-out')));
    await tester.pumpAndSettle();
    expect(find.byType(SignOutDraftsDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
  }

  for (final width in [600.0, 834.0, 1199.0]) {
    testWidgets('${width.toInt()} dp, tablet layout, from a shell page: '
        'centred on the content area, at most 400 wide', (tester) async {
      await pumpTabletModalHost(
        tester,
        width: width,
        wrap: providers,
        trigger: button,
      );

      await open(tester);

      final box = openDialogRect(tester);
      final content = tabletContentRect(Size(width, 1194));
      expect(box.center.dx, closeTo(content.center.dx, 1));
      expect(box.left, greaterThanOrEqualTo(content.left + 24 - 0.5));
      expect(box.width, lessThanOrEqualTo(AppSize.alertDialogMax + 0.5));
    });
  }

  testWidgets('tablet layout, from the rail (the account chip): centred on '
      'the content area, and "Keep" signs out', (tester) async {
    await pumpTabletModalHost(
      tester,
      width: 1024,
      wrap: providers,
      trigger: (_) => const SizedBox(),
      accountChipBuilder: (_) => Builder(builder: button),
    );

    await open(tester);

    final content = tabletContentRect(const Size(1024, 1194));
    expect(openDialogRect(tester).center.dx, closeTo(content.center.dx, 1));

    await tester.tap(find.text('Keep'));
    await tester.pumpAndSettle();
    expect(find.byType(SignOutDraftsDialog), findsNothing);
    verify(() => auth.add(const AuthSignOutRequested())).called(1);
    expect(drafts.wiped, isEmpty);
  });

  testWidgets('tablet layout, from a full-screen route (no rail): centred on '
      'the window', (tester) async {
    await pumpTabletModalHost(
      tester,
      width: 834,
      inShell: false,
      wrap: providers,
      trigger: button,
    );

    await open(tester);

    final box = openDialogRect(tester);
    expect(box.center.dx, closeTo(834 / 2, 1));
    expect(box.width, lessThanOrEqualTo(AppSize.alertDialogMax + 0.5));
  });

  for (final flags in [
    {kFeatureUiShell},
    {kFeatureUiTablet},
    <String>{},
  ]) {
    testWidgets('834 dp with only $flags: centred on the window, as before', (
      tester,
    ) async {
      await pumpTabletModalHost(
        tester,
        width: 834,
        flags: flags,
        wrap: providers,
        trigger: button,
      );

      await open(tester);

      expect(openDialogRect(tester).center.dx, closeTo(834 / 2, 1));
    });
  }

  testWidgets('599 dp with both flags: centred on the window, as before', (
    tester,
  ) async {
    await pumpTabletModalHost(
      tester,
      width: 599,
      wrap: providers,
      trigger: button,
    );

    await open(tester);

    expect(openDialogRect(tester).center.dx, closeTo(599 / 2, 1));
  });

  // D1: the desktop layout centres it on the shell's feed column, from a
  // page and from the rail (the account chip), the host still resolved at
  // the button.
  for (final width in [1200.0, 1440.0]) {
    testWidgets('${width.toInt()} dp with both flags, from a shell page: '
        'centred on the desktop column, at most 400 wide', (tester) async {
      await pumpTabletModalHost(
        tester,
        width: width,
        wrap: providers,
        trigger: button,
      );

      await open(tester);

      final box = openDialogRect(tester);
      final column = desktopColumnRect(tester, Size(width, 1194));
      expect(box.center.dx, closeTo(column.center.dx, 1));
      expect(box.width, lessThanOrEqualTo(AppSize.alertDialogMax + 0.5));
    });
  }

  testWidgets('1440 dp with both flags, from the rail: centred on the '
      'desktop column', (tester) async {
    await pumpTabletModalHost(
      tester,
      width: 1440,
      wrap: providers,
      trigger: (_) => const SizedBox(),
      accountChipBuilder: (_) => Builder(builder: button),
    );

    await open(tester);

    final column = desktopColumnRect(tester, const Size(1440, 1194));
    expect(openDialogRect(tester).center.dx, closeTo(column.center.dx, 1));
  });

  for (final flags in [
    {kFeatureUiShell},
    {kFeatureUiTablet},
    <String>{},
  ]) {
    testWidgets('1200 dp with only $flags: centred on the window, as before', (
      tester,
    ) async {
      await pumpTabletModalHost(
        tester,
        width: 1200,
        flags: flags,
        wrap: providers,
        trigger: button,
      );

      await open(tester);

      expect(openDialogRect(tester).center.dx, closeTo(1200 / 2, 1));
    });
  }
}
