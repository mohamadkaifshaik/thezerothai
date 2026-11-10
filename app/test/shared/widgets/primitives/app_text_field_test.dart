import 'package:dzeroth/core/theme/app_theme.dart';
import 'package:dzeroth/shared/widgets/primitives/app_text_field.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../../support/app_fonts.dart';
import '../../../support/contrast.dart';
import '../../../support/theme_harness.dart';

const _longError =
    'That handle is already taken, and handles cannot be changed back once '
    'a different one has been saved on this account.';

Widget _field({
  String? hint,
  String? errorText,
  String? okText,
  AppFieldKind kind = AppFieldKind.plain,
  bool area = false,
  List<String>? autofillHints,
  TextEditingController? controller,
  FocusNode? focusNode,
}) => Padding(
  padding: const EdgeInsets.all(16),
  child: AppTextField(
    label: 'Email address',
    kind: kind,
    hint: hint,
    errorText: errorText,
    okText: okText,
    area: area,
    autofillHints: autofillHints,
    controller: controller,
    focusNode: focusNode,
  ),
);

/// The live-region Semantics inside the message row with [key].
Finder _live(String key) => find.descendant(
  of: find.byKey(ValueKey(key)),
  matching: find.byWidgetPredicate(
    (w) => w is Semantics && w.properties.liveRegion == true,
  ),
);

SemanticsNode _fieldNode(WidgetTester tester) =>
    tester.getSemantics(find.byType(TextField));

void main() {
  setUpAll(() async {
    if (goldensEnabled) await loadAppFonts();
  });

  group('semantics', () {
    testWidgets('field node carries label, hint and the text-field flag', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, _field(hint: 'We never share it.'));
      final data = _fieldNode(tester).getSemanticsData();
      expect(data.label, contains('Email address'));
      expect(data.hint, contains('We never share it.'));
      expect(data.flagsCollection.isTextField, isTrue);
      handle.dispose();
    });

    testWidgets('the error replaces the hint and marks the field invalid', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        _field(hint: 'We never share it.', errorText: 'Enter a valid email.'),
      );
      final data = _fieldNode(tester).getSemanticsData();
      expect(data.label, contains('Email address'));
      expect(data.hint, contains('Enter a valid email.'));
      expect(data.hint, isNot(contains('We never share it.')));
      expect(data.validationResult, SemanticsValidationResult.invalid);
      // Visually too: the error takes the hint's place.
      expect(find.text('We never share it.'), findsNothing);
      expect(find.text('Enter a valid email.'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('semanticsLabel replaces the visible label in speech', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(
        tester,
        const AppTextField(
          label: 'Code',
          semanticsLabel: 'Six digit sign-in code',
          kind: AppFieldKind.oneTimeCode,
        ),
      );
      expect(
        _fieldNode(tester).getSemanticsData().label,
        contains('Six digit sign-in code'),
      );
      handle.dispose();
    });

    testWidgets('the error is one live region and the decoration adds none', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, _field(errorText: 'Enter a valid email.'));
      final nodes = <SemanticsNode>[];
      void walk(SemanticsNode n) {
        final d = n.getSemanticsData();
        if (d.label.contains('Enter a valid email.') ||
            d.hint.contains('Enter a valid email.')) {
          nodes.add(n);
        }
        n.visitChildren((c) {
          walk(c);
          return true;
        });
      }

      walk(tester.getSemantics(find.byType(Scaffold)));
      final live = nodes.where(
        (n) => n.getSemanticsData().flagsCollection.isLiveRegion,
      );
      expect(live, hasLength(1));
      // The only other carrier is the field's hint, never a second label.
      expect(
        nodes.where((n) => n.getSemanticsData().label.contains('valid email')),
        hasLength(1),
      );
      handle.dispose();
    });

    testWidgets('the live region does not re-announce on rebuild', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, _field(errorText: 'Enter a valid email.'));
      final finder = _live('app-text-field-error');
      final before = tester.getSemantics(finder);
      final beforeId = before.id;
      final beforeLabel = before.label;
      // Same text, rebuilt: same node, same label (no new semantics event).
      await pumpThemed(tester, _field(errorText: 'Enter a valid email.'));
      final after = tester.getSemantics(finder);
      expect(after.id, beforeId);
      expect(after.label, beforeLabel);
      expect(after.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      // A changed message updates the same live node's label.
      await pumpThemed(tester, _field(errorText: 'Email is required.'));
      expect(tester.getSemantics(finder).label, 'Email is required.');
      // No error: no live region at all.
      await pumpThemed(tester, _field());
      expect(finder, findsNothing);
      handle.dispose();
    });

    testWidgets('the ok message is a live region in the indicator colour', (
      tester,
    ) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, _field(okText: 'Handle is available.'));
      final node = tester.getSemantics(_live('app-text-field-ok'));
      expect(node.label, 'Handle is available.');
      expect(node.getSemanticsData().flagsCollection.isLiveRegion, isTrue);
      handle.dispose();
    });

    testWidgets('the error wins over the ok message', (tester) async {
      await pumpThemed(tester, _field(errorText: 'Bad.', okText: 'Good.'));
      expect(find.text('Bad.'), findsOneWidget);
      expect(find.text('Good.'), findsNothing);
    });

    testWidgets('the error shows an icon as well as colour', (tester) async {
      await pumpThemed(tester, _field(errorText: 'Enter a valid email.'));
      expect(find.byIcon(Icons.error_outline), findsOneWidget);
    });
  });

  group('autofill hints', () {
    const expected = <AppFieldKind, List<String>>{
      AppFieldKind.email: [AutofillHints.email],
      AppFieldKind.username: [AutofillHints.username],
      AppFieldKind.currentPassword: [AutofillHints.password],
      AppFieldKind.newPassword: [AutofillHints.newPassword],
      AppFieldKind.oneTimeCode: [AutofillHints.oneTimeCode],
      AppFieldKind.plain: <String>[],
    };

    for (final kind in AppFieldKind.values) {
      testWidgets('${kind.name} sets ${expected[kind]}', (tester) async {
        await pumpThemed(tester, _field(kind: kind));
        final text = tester.widget<TextField>(find.byType(TextField));
        final hints = expected[kind]!;
        expect(text.autofillHints ?? const <String>[], hints);
        expect(
          const AppTextField(
            label: 'x',
            kind: AppFieldKind.plain,
          ).effectiveAutofillHints,
          isEmpty,
        );
      });
    }

    test('every credential kind has at least one hint', () {
      for (final kind in AppFieldKind.values.where((k) => k.isCredential)) {
        expect(kind.autofillHints, isNotEmpty, reason: kind.name);
      }
    });

    testWidgets('plain accepts its own hints; other kinds reject overrides', (
      tester,
    ) async {
      await pumpThemed(
        tester,
        _field(autofillHints: const [AutofillHints.name]),
      );
      expect(tester.widget<TextField>(find.byType(TextField)).autofillHints, [
        AutofillHints.name,
      ]);
      expect(
        () => AppTextField(
          label: 'x',
          kind: AppFieldKind.email,
          autofillHints: const [AutofillHints.name],
        ),
        throwsAssertionError,
      );
    });

    testWidgets('credentials turn autocorrect and suggestions off', (
      tester,
    ) async {
      await pumpThemed(tester, _field(kind: AppFieldKind.username));
      final text = tester.widget<TextField>(find.byType(TextField));
      expect(text.autocorrect, isFalse);
      expect(text.enableSuggestions, isFalse);
    });
  });

  group('password toggle', () {
    testWidgets('starts obscured; the 48 dp toggle reveals it', (tester) async {
      final handle = tester.ensureSemantics();
      await pumpThemed(tester, _field(kind: AppFieldKind.currentPassword));
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isTrue,
      );
      final toggle = find.byTooltip('Show password');
      expect(toggle, findsOneWidget);
      final size = tester.getSize(toggle);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      await tester.tap(toggle);
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).obscureText,
        isFalse,
      );
      expect(find.byTooltip('Hide password'), findsOneWidget);
      handle.dispose();
    });

    testWidgets('non-secret kinds have no toggle', (tester) async {
      await pumpThemed(tester, _field(kind: AppFieldKind.email));
      expect(find.byType(IconButton), findsNothing);
    });
  });

  group('area, counter and controller', () {
    testWidgets('the area is at least 96 dp tall', (tester) async {
      await pumpThemed(tester, _field(area: true));
      expect(
        tester.getSize(find.byType(TextField)).height,
        greaterThanOrEqualTo(96),
      );
    });

    testWidgets('the counter slot renders', (tester) async {
      await pumpThemed(
        tester,
        const AppTextField(
          label: 'Bio',
          kind: AppFieldKind.plain,
          counter: Text('7 / 160'),
        ),
      );
      expect(find.text('7 / 160'), findsOneWidget);
    });

    testWidgets('typing reaches the controller', (tester) async {
      final c = TextEditingController();
      addTearDown(c.dispose);
      await pumpThemed(tester, _field(controller: c));
      await tester.enterText(find.byType(TextField), 'a@b.co');
      expect(c.text, 'a@b.co');
    });
  });

  group('colours', () {
    for (final dark in [false, true]) {
      final name = dark ? 'dark' : 'light';
      testWidgets('$name border >= 3:1; focus border is the indicator', (
        tester,
      ) async {
        final focus = FocusNode();
        addTearDown(focus.dispose);
        await pumpThemed(
          tester,
          _field(focusNode: focus),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        final context = tester.element(find.byType(TextField));
        final theme = Theme.of(context);
        final scheme = theme.colorScheme;
        final fill = theme.inputDecorationTheme.fillColor!;
        final page = Color.alphaBlend(fill, scheme.surface);
        expect(contrast(scheme.outline, page), greaterThanOrEqualTo(3));
        expect(
          contrast(scheme.outline, scheme.surface),
          greaterThanOrEqualTo(3),
        );

        InputBorder border() =>
            tester
                .widget<InputDecorator>(find.byType(InputDecorator))
                .decoration
                .enabledBorder ??
            theme.inputDecorationTheme.enabledBorder!;
        expect(border().borderSide.color, scheme.outline);

        // The widget adds no borders of its own: the resolved ones are the theme's.
        final own = tester
            .widget<TextField>(find.byType(TextField))
            .decoration!;
        expect(own.focusedBorder, theme.inputDecorationTheme.focusedBorder);
        expect(own.enabledBorder, theme.inputDecorationTheme.enabledBorder);

        focus.requestFocus();
        await tester.pumpAndSettle();
        expect(
          tester.widget<InputDecorator>(find.byType(InputDecorator)).isFocused,
          isTrue,
        );
        final focused = theme.inputDecorationTheme.focusedBorder!;
        expect(focused.borderSide.color, context.appColors.selectedIndicator);
        expect(focused.borderSide.width, 2);
        expect(
          contrast(context.appColors.selectedIndicator, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });

      testWidgets('$name error and ok text >= 4.5:1 on the page', (
        tester,
      ) async {
        await pumpThemed(
          tester,
          _field(errorText: 'Enter a valid email.'),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        final context = tester.element(find.byType(TextField));
        final scheme = Theme.of(context).colorScheme;
        final errorText = tester.widget<Text>(
          find.text('Enter a valid email.'),
        );
        expect(errorText.style!.color, scheme.error);
        expect(
          contrast(scheme.error, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(context.appColors.selectedIndicator, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrast(scheme.onSurfaceVariant, scheme.surface),
          greaterThanOrEqualTo(4.5),
        );
      });

      testWidgets('$name an error turns the border to the error colour', (
        tester,
      ) async {
        await pumpThemed(
          tester,
          _field(errorText: 'Enter a valid email.'),
          brightness: dark ? Brightness.dark : Brightness.light,
        );
        final decorator = tester.widget<InputDecorator>(
          find.byType(InputDecorator),
        );
        expect(decorator.decoration.error, isNotNull);
        expect(
          decorator.decoration.errorBorder,
          Theme.of(tester.element(find.byType(TextField)))
              .inputDecorationTheme
              .errorBorder,
        );
        expect(
          decorator.decoration.focusedErrorBorder,
          Theme.of(tester.element(find.byType(TextField)))
              .inputDecorationTheme
              .focusedErrorBorder,
        );
        final theme = Theme.of(tester.element(find.byType(TextField)));
        expect(
          theme.inputDecorationTheme.errorBorder!.borderSide.color,
          theme.colorScheme.error,
        );
        expect(decorator.isFocused, isFalse);
      });
    }
  });

  group('layout matrix', () {
    forEachThemeAndWidth(
      'long error and hint reflow without overflow and keep 48 dp',
      (tester, env) async {
        final handle = tester.ensureSemantics();
        await pumpThemed(
          tester,
          SingleChildScrollView(
            child: _field(
              kind: AppFieldKind.newPassword,
              hint: 'Use at least 12 characters with a mix of words.',
              errorText: _longError,
            ),
          ),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        expect(tester.takeException(), isNull);
        expect(find.text(_longError), findsOneWidget);
        await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
        await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
        expect(
          tester.getSize(find.byType(TextField)).height,
          greaterThanOrEqualTo(48),
        );
        await expectGolden(
          tester,
          find.byType(AppTextField),
          'text_field',
          env,
        );
        handle.dispose();
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );

    forEachThemeAndWidth(
      'label stays above the field and the column grows at 2.0',
      (tester, env) async {
        await pumpThemed(
          tester,
          SingleChildScrollView(child: _field(hint: 'Hint')),
          brightness: env.brightness,
          size: env.size,
          textScale: env.textScale,
        );
        final label = tester.getRect(find.text('Email address'));
        final hint = tester.getRect(find.text('Hint'));
        final field = tester.getRect(find.byType(TextField));
        expect(label.bottom, lessThanOrEqualTo(hint.top));
        expect(hint.bottom, lessThanOrEqualTo(field.top));
        expect(tester.takeException(), isNull);
      },
      widths: kRedesignWidths,
      textScales: kRedesignTextScales,
      heights: kRedesignHeights,
    );
  });
}
