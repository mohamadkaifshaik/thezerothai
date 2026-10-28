import 'package:intl/intl.dart';

/// One planned paid plan shown (never sold) in the Premium pop-up (W8-5,
/// ADR-0026 D3). Prices are in paise, monthly, inclusive of GST.
class PremiumPlan {
  const PremiumPlan({required this.name, required this.pricePaise});

  final String name;

  /// Monthly price in paise (1 rupee = 100 paise), inclusive of GST.
  final int pricePaise;

  /// The billing period. Only monthly exists; there is no annual price.
  static const period = 'month';

  /// "₹235/month" (no decimals for whole rupees).
  String get priceLabel => '${formatRupees(pricePaise)}/$period';

  /// "₹235 a month" for speech.
  String get spokenPrice => '${formatRupees(pricePaise)} a $period';
}

/// The only place a Premium price lives. A change is a one-line, reviewed
/// copy change approved by the founder (ADR-0026 D3).
const kPremiumPlans = <PremiumPlan>[
  PremiumPlan(name: 'Plus', pricePaise: 23500),
  PremiumPlan(name: 'Premium', pricePaise: 85000),
];

/// Formats [paise] as rupees in the `en_IN` format with a "₹" sign: no
/// decimals for whole rupees, two otherwise ("₹235", "₹1,000", "₹99.50").
String formatRupees(int paise) {
  final whole = paise % 100 == 0;
  return NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: whole ? 0 : 2,
  ).format(paise / 100);
}
