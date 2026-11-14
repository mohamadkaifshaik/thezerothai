import 'dart:convert';

import 'subscription_models.dart';

/// A reviewed build-time catalog, never a source of paid authorization.
/// Invalid configuration disables new checkout; identified restore can still run.
Map<String, SubscriptionTier> parseMonthlySubscriptionProducts(String raw) {
  if (raw.isEmpty || raw.length > 16384) return const {};
  try {
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic> ||
        decoded.isEmpty ||
        decoded.length > 32) {
      return const {};
    }
    final products = <String, SubscriptionTier>{};
    for (final entry in decoded.entries) {
      if (entry.key.isEmpty ||
          entry.key.length > 256 ||
          RegExp(r'[\x00-\x20]').hasMatch(entry.key)) {
        return const {};
      }
      final tier = switch (entry.value) {
        'plus' => SubscriptionTier.plus,
        'premium' => SubscriptionTier.premium,
        _ => null,
      };
      if (tier == null) return const {};
      products[entry.key] = tier;
    }
    return Map.unmodifiable(products);
  } on FormatException {
    return const {};
  }
}
