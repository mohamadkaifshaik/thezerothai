import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/user/follow_pill.dart';
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: Scaffold(body: Center(child: child)),
    );

BoxDecoration _decoration(WidgetTester tester) {
  final box = tester.widget<DecoratedBox>(
    find.descendant(
      of: find.byType(FollowPill),
      matching: find.byType(DecoratedBox),
    ),
  );
  return box.decoration as BoxDecoration;
}

Size _pillSize(WidgetTester tester) => tester.getSize(
  find
      .descendant(
        of: find.byType(FollowPill),
        matching: find.byType(DecoratedBox),
      )
      .first,
);

TextStyle _labelStyle(WidgetTester tester, String text) =>
    tester.widget<Text>(find.text(text)).style!;

void main() {
  group('size', () {
    testWidgets('compact is 32dp and large 36dp, with a 48dp hit target', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', onPressed: () {})),
      );
      expect(_pillSize(tester).height, 32);
      expect(_pillSize(tester).width, greaterThanOrEqualTo(77));
      expect(tester.getSize(find.byType(FollowPill)).height, 48);
      expect(_labelStyle(tester, 'Follow').fontSize, 14);
      expect(_labelStyle(tester, 'Follow').fontWeight, FontWeight.w700);

      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', large: true, onPressed: () {})),
      );
      expect(_pillSize(tester).height, 36);
      expect(tester.getSize(find.byType(FollowPill)).height, 48);
      expect(_labelStyle(tester, 'Follow').fontSize, 15);
    });

    testWidgets('a tap in the 48dp box outside the pill presses it', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', onPressed: () => taps++)),
      );
      final box = tester.getRect(find.byType(FollowPill));
      // 7dp above the 32dp pill, still inside the 48dp box.
      await tester.tapAt(box.topCenter + const Offset(0, 3));
      expect(taps, 1);
    });

    testWidgets('grows with 2x text instead of clipping', (tester) async {
      await tester.pumpWidget(
        MediaQuery(
          data: const MediaQueryData(
            size: Size(320, 640),
            textScaler: TextScaler.linear(2),
          ),
          child: _host(FollowPill(label: 'Follow back', onPressed: () {})),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(_pillSize(tester).height, greaterThanOrEqualTo(32));
    });
  });

  group('colours', () {
    testWidgets('Follow: dark theme pale pill, light theme near-black', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          FollowPill(label: 'Follow', onPressed: () {}),
          brightness: Brightness.dark,
        ),
      );
      expect(_decoration(tester).color, const Color(0xFFEFF3F4));
      expect(_decoration(tester).border, isNull);
      expect(_decoration(tester).boxShadow, isNull);
      expect(_decoration(tester).gradient, isNull);
      expect(_labelStyle(tester, 'Follow').color, const Color(0xFF0F1419));
      expect(
        _decoration(tester).borderRadius,
        BorderRadius.circular(AppRadius.pill),
      );

      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', onPressed: () {})),
      );
      await tester.pumpAndSettle();
      expect(_decoration(tester).color, const Color(0xFF0F1419));
      expect(_labelStyle(tester, 'Follow').color, const Color(0xFFFFFFFF));
    });

    testWidgets('onDark draws the dark-theme pill in the light theme', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', onDark: true, onPressed: () {})),
      );
      expect(_decoration(tester).color, const Color(0xFFEFF3F4));
    });

    testWidgets('Following: transparent, 1dp border per theme', (tester) async {
      for (final (brightness, border) in [
        (Brightness.dark, const Color(0xFF536471)),
        (Brightness.light, const Color(0xFFCFD9DE)),
      ]) {
        await tester.pumpWidget(
          _host(
            FollowPill(
              label: 'Following',
              hoverLabel: 'Unfollow',
              style: FollowPillStyle.outlined,
              onPressed: () {},
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        final d = _decoration(tester);
        expect(d.color, Colors.transparent);
        final side = (d.border! as Border).top;
        expect(side.color, border);
        expect(side.width, 1);
        expect(
          _labelStyle(tester, 'Following').color,
          ThemeData(brightness: brightness).colorScheme.onSurface,
        );
      }
    });

    testWidgets('Unblock is a red filled pill with a white label', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          FollowPill(
            label: 'Unblock',
            style: FollowPillStyle.danger,
            onPressed: () {},
          ),
        ),
      );
      expect(_decoration(tester).color, const Color(0xFFF4212E));
      expect(_labelStyle(tester, 'Unblock').color, const Color(0xFFFFFFFF));
    });
  });

  group('hover and press', () {
    Widget following({VoidCallback? onPressed}) => _host(
      FollowPill(
        label: 'Following',
        hoverLabel: 'Unfollow',
        style: FollowPillStyle.outlined,
        onPressed: onPressed ?? () {},
      ),
    );

    testWidgets('a mouse over Following reads a red Unfollow', (tester) async {
      await tester.pumpWidget(following());
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(find.text('Unfollow'), findsNothing);

      await mouse.moveTo(tester.getCenter(find.byType(FollowPill)));
      await tester.pump();

      expect(find.text('Following'), findsNothing);
      expect(_labelStyle(tester, 'Unfollow').color, const Color(0xFFF4212E));
      final d = _decoration(tester);
      expect(d.color, const Color(0x1AF4212E));
      expect((d.border! as Border).top.color, const Color(0x80F4212E));

      await mouse.moveTo(Offset.zero);
      await tester.pump();
      expect(find.text('Following'), findsOneWidget);
    });

    testWidgets('pressing reads Unfollow too, and the tap still fires', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(following(onPressed: () => taps++));
      final touch = await tester.startGesture(
        tester.getCenter(find.byType(FollowPill)),
      );
      await tester.pump();
      expect(find.text('Unfollow'), findsOneWidget);
      await touch.up();
      await tester.pump();
      expect(taps, 1);
      expect(find.text('Following'), findsOneWidget);
    });

    testWidgets('Follow does not change on hover', (tester) async {
      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', onPressed: () {})),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(
        location: tester.getCenter(find.byType(FollowPill)),
      );
      addTearDown(mouse.removePointer);
      await tester.pump();
      expect(find.text('Follow'), findsOneWidget);
      expect(_decoration(tester).color, const Color(0xFF0F1419));
    });
  });

  group('busy and disabled', () {
    testWidgets('busy keeps the size and shows a spinner in the label colour', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', busy: true, onPressed: null)),
      );
      expect(_pillSize(tester).height, 32);
      expect(_pillSize(tester).width, greaterThanOrEqualTo(77));
      final spinner = tester.widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator),
      );
      expect(spinner.color, const Color(0xFFFFFFFF));
      // The label stays laid out, invisibly, so the pill keeps its size.
      expect(
        tester
            .widget<Opacity>(
              find
                  .ancestor(
                    of: find.text('Follow'),
                    matching: find.byType(Opacity),
                  )
                  .first,
            )
            .opacity,
        0,
      );
    });

    testWidgets('a busy pill on the dark hero spins in the dark label ink', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          const FollowPill(
            label: 'Follow',
            busy: true,
            onDark: true,
            large: true,
            onPressed: null,
          ),
        ),
      );
      expect(
        tester
            .widget<CircularProgressIndicator>(
              find.byType(CircularProgressIndicator),
            )
            .color,
        AppFollowButton.darkFillText,
      );
    });

    testWidgets('busy keeps the exact width of the idle pill', (tester) async {
      for (final label in ['Follow back', 'Following', 'Follow']) {
        await tester.pumpWidget(
          _host(FollowPill(label: label, onPressed: () {})),
        );
        final idle = _pillSize(tester);
        await tester.pumpWidget(
          _host(FollowPill(label: label, busy: true, onPressed: null)),
        );
        expect(_pillSize(tester), idle, reason: label);
      }
    });

    testWidgets('disabled is drawn at 50 percent and ignores taps', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(const FollowPill(label: 'Follow', onPressed: null)),
      );
      expect(
        tester
            .widget<Opacity>(
              find.descendant(
                of: find.byType(FollowPill),
                matching: find.byType(Opacity),
              ),
            )
            .opacity,
        0.5,
      );
    });
  });

  group('keyboard', () {
    Finder ring() => find.descendant(
      of: find.byType(FollowPill),
      matching: find.byWidgetPredicate(
        (w) =>
            w is DecoratedBox &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).border is Border &&
            ((w.decoration as BoxDecoration).border! as Border).top.width == 2,
      ),
    );

    testWidgets('a 2dp ring, 2dp clear of the pill, shows on keyboard focus '
        'only, and Enter and Space activate', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', onPressed: () => taps++)),
      );
      expect(ring(), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(ring(), findsOneWidget);
      final pill = _pillSize(tester);
      final ringRect = tester.getRect(ring());
      final pillRect = tester.getRect(
        find
            .descendant(
              of: find.byType(FollowPill),
              matching: find.byType(DecoratedBox),
            )
            .first,
      );
      expect(ringRect.width, pill.width + 8);
      expect(ringRect.height, pill.height + 8);
      expect(ringRect.center, pillRect.center);
      expect(
        ((tester.widget<DecoratedBox>(ring()).decoration as BoxDecoration)
                    .border!
                as Border)
            .top
            .color,
        ThemeData().colorScheme.primary,
      );
      // The ring does not move the pill.
      expect(_pillSize(tester), pill);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.space);
      await tester.pump();
      expect(taps, 2);
    });

    testWidgets('a tap does not show the ring', (tester) async {
      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', onPressed: () {})),
      );
      await tester.tap(find.byType(FollowPill));
      await tester.pump();
      expect(ring(), findsNothing);
    });

    testWidgets('a busy pill is neither tappable nor focusable', (
      tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(FollowPill(label: 'Follow', busy: true, onPressed: () => taps++)),
      );
      await tester.tap(find.byType(FollowPill));
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(taps, 0);
      expect(ring(), findsNothing);
    });
  });
}
