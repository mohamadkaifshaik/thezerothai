import 'package:dzeroth/features/shells/domain/premium_plans.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The W8 copy guard (ADR-0026 D3, plan W8-5 and W8-8): what the shell pages,
/// the More menu and the Premium pop-up may never say. One implementation,
/// used by the Premium dialog test and the cross-page guard
/// (`shells_copy_guard_test.dart`), so a copy change is checked everywhere.

/// Purchase, sign-up, urgency and annual-price words (D3 "may not show").
final RegExp kShellForbiddenWords = RegExp(
  r'subscribe|upgrade|buy|trial|waitlist|notify me|pre-order|reserve|'
  r'limited|early bird|/year|annual',
  caseSensitive: false,
);

const _months =
    r'(?:jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|'
    r'aug(?:ust)?|sep(?:t(?:ember)?)?|oct(?:ober)?|nov(?:ember)?|'
    r'dec(?:ember)?)';

/// Any date: a month name with a year ("October 2026", "Oct 28, 2026",
/// "28 October 2026"), a digit date ("28/10", "2026-10-28", "28.10.2026") or a
/// bare year.
final List<RegExp> kShellDatePatterns = [
  RegExp(
    '\\b$_months\\b\\.?\\s*(?:\\d{1,2}(?:st|nd|rd|th)?,?\\s*)?(?:19|20)\\d{2}\\b',
    caseSensitive: false,
  ),
  RegExp('\\b\\d{1,2}(?:st|nd|rd|th)?\\s+$_months\\b', caseSensitive: false),
  RegExp(r'\b\d{1,4}[/.-]\d{1,2}(?:[/.-]\d{1,4})?\b'),
  RegExp(r'\b(?:19|20)\d{2}\b'),
];

/// A rupee amount: the sign, "Rs" or "INR" before digits.
final RegExp kShellAmount = RegExp(
  r'(?:₹|\brs\.?|\binr)\s*\d[\d,]*(?:\.\d+)?',
  caseSensitive: false,
);

/// The amounts `kPremiumPlans` may show, formatted as the dialog formats them.
List<String> get kAllowedPlanAmounts => [
  for (final p in kPremiumPlans) formatRupees(p.pricePaise),
];

/// The strings [scope] (default: the whole tree) shows: `Text` and rich text,
/// tooltips and explicit semantics labels, in tree order.
String shellVisibleText(WidgetTester tester, [Finder? scope]) {
  Finder under(Finder f) =>
      scope == null ? f : find.descendant(of: scope, matching: f);
  final out = <String>[];
  for (final w in tester.widgetList<Text>(under(find.byType(Text)))) {
    out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
  }
  for (final w in tester.widgetList<SelectableText>(
    under(find.byType(SelectableText)),
  )) {
    out.add(w.data ?? w.textSpan?.toPlainText() ?? '');
  }
  for (final w in tester.widgetList<Tooltip>(under(find.byType(Tooltip)))) {
    if (w.message != null) out.add(w.message!);
  }
  for (final w in tester.widgetList<Semantics>(under(find.byType(Semantics)))) {
    final label = w.properties.label;
    if (label != null && label.isNotEmpty) out.add(label);
  }
  return out.join('\n');
}

/// Fails when [text] has a forbidden word, a date, or a rupee amount. With
/// [allowPlanAmounts] (the Premium pop-up only) the amounts in
/// `kPremiumPlans` are allowed, and every other amount still fails.
void expectCleanShellCopy(
  String text, {
  bool allowPlanAmounts = false,
  String where = 'copy',
}) {
  expect(
    kShellForbiddenWords.firstMatch(text)?[0],
    isNull,
    reason: '$where has a forbidden word:\n$text',
  );
  for (final date in kShellDatePatterns) {
    expect(
      date.firstMatch(text)?[0],
      isNull,
      reason: '$where has a date (${date.pattern}):\n$text',
    );
  }
  final allowed = allowPlanAmounts ? kAllowedPlanAmounts : const <String>[];
  for (final m in kShellAmount.allMatches(text)) {
    expect(
      allowed,
      contains(m[0]),
      reason:
          '$where has a rupee amount outside the Premium pop-up '
          'or not in kPremiumPlans: ${m[0]}',
    );
  }
}
