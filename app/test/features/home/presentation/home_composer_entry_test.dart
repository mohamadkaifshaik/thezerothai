import 'package:bloc_test/bloc_test.dart';
import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/features/home/presentation/widgets/home_composer_entry.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_bloc.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_event.dart';
import 'package:dzeroth/features/onboarding/presentation/bloc/onboarding_state.dart';
import 'package:dzeroth/gen/dzeroth/identity/v1/identity.pb.dart' as identity;
import 'package:dzeroth/shared/widgets/post/post_card.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/theme_harness.dart';

class _Onboarding extends MockBloc<OnboardingEvent, OnboardingState>
    implements OnboardingBloc {}

/// The Home entry row (R1 review): the pill is painted as ink on the
/// Material, so the row's focus highlight and ripple show over it (an opaque
/// box inside the InkWell hid them); keyboard focus also draws the teal
/// focus border; the avatar shows the viewer's initials; it lines up with
/// the post cards.
void main() {
  late _Onboarding onboarding;

  setUp(() {
    onboarding = _Onboarding();
    whenListen(
      onboarding,
      const Stream<OnboardingState>.empty(),
      initialState: OnboardingState(
        status: OnboardingStatus.ready,
        profile: identity.Profile(
          userId: 'me',
          handle: 'meera',
          displayName: 'Meera Kapoor',
        ),
      ),
    );
    addTearDown(onboarding.close);
  });

  Future<void> pump(WidgetTester tester, {double width = 360}) => pumpThemed(
    tester,
    BlocProvider<OnboardingBloc>.value(
      value: onboarding,
      child: const Align(
        alignment: Alignment.topCenter,
        child: HomeComposerEntry(),
      ),
    ),
    size: Size(width, 800),
  );

  Finder inkWell() => find.descendant(
    of: find.byType(HomeComposerEntry),
    matching: find.byType(InkWell),
  );

  testWidgets('nothing opaque sits between the InkWell and its ink', (
    tester,
  ) async {
    await pump(tester);

    // The pill used to be an opaque DecoratedBox inside the InkWell (the
    // avatar's own tint circle is not in the way of the row's ink).
    final opaque = find.descendant(
      of: inkWell(),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color != null &&
            (w.decoration as BoxDecoration).shape != BoxShape.circle,
      ),
    );
    expect(opaque, findsNothing);
    expect(
      find.descendant(of: inkWell(), matching: find.byType(Ink)),
      findsOneWidget,
    );
  });

  testWidgets('keyboard focus: a highlight and the teal focus border', (
    tester,
  ) async {
    await pump(tester);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus?.context;
    expect(
      focused?.findAncestorWidgetOfExactType<HomeComposerEntry>(),
      isNotNull,
    );
    final ink = tester.widget<Ink>(
      find.descendant(of: inkWell(), matching: find.byType(Ink)),
    );
    final border = (ink.decoration! as BoxDecoration).border! as Border;
    final theme = Theme.of(tester.element(inkWell()));
    expect(border.top.color, theme.colorScheme.primary);
    expect(border.top.width, 2);
  });

  testWidgets('the avatar shows the viewer\'s initials', (tester) async {
    await pump(tester);

    expect(find.text('MK'), findsOneWidget);
  });

  for (final width in const [360.0, 600.0]) {
    testWidgets('at $width the avatar sits in the cards\' avatar column', (
      tester,
    ) async {
      await pump(tester, width: width);

      final avatar = tester.getRect(find.byType(CircleAvatar));
      expect(avatar.width, AppSize.avatarPost);
      expect(
        avatar.center.dx,
        closeTo(postCardGutter(width) + AppSpacing.minTapTarget / 2, 0.5),
      );
    });
  }
}
