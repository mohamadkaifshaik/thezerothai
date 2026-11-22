import 'package:intl/intl.dart';

/// India launch pricing used for the preview and INR product validation.
/// Prices are in paise, monthly, inclusive of GST.
class PremiumPlan {
  const PremiumPlan({required this.name, required this.pricePaise});

  final String name;

  /// Monthly price in paise (1 rupee = 100 paise), inclusive of GST.
  final int pricePaise;

  /// The billing period. Only monthly exists; there is no annual price.
  static const period = 'month';

  /// "₹99/month" (no decimals for whole rupees).
  String get priceLabel => '${formatRupees(pricePaise)}/$period';

  /// "₹99 a month" for speech.
  String get spokenPrice => '${formatRupees(pricePaise)} a $period';
}

/// The single paid launch plan in India.
const kPremiumPlans = <PremiumPlan>[
  PremiumPlan(name: 'Plus', pricePaise: 9900),
];

/// Formats [paise] as rupees in the `en_IN` format with a "₹" sign: no
/// decimals for whole rupees, two otherwise ("₹99", "₹1,000", "₹99.50").
String formatRupees(int paise) {
  final whole = paise % 100 == 0;
  return NumberFormat.currency(
    locale: 'en_IN',
    symbol: '₹',
    decimalDigits: whole ? 0 : 2,
  ).format(paise / 100);
}
