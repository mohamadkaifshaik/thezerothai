import 'package:firebase_analytics/firebase_analytics.dart';

import 'analytics_event.dart';
import 'telemetry_interfaces.dart';

/// Google Analytics for Firebase behind [UsageAnalytics]. One of the only two
/// files that import an SDK. Never constructed on web or iOS (see
/// `createTelemetry`). No user id or property is ever set (Q10 (f)).
///
/// ADR-0032 C3: on, `setConsent(analytics_storage: granted)` then collection
/// on; off, collection off then `setConsent(denied)`.
class FirebaseUsageAnalytics implements UsageAnalytics {
  FirebaseUsageAnalytics([FirebaseAnalytics? analytics])
    : _analytics = analytics ?? FirebaseAnalytics.instance;

  final FirebaseAnalytics _analytics;

  @override
  Future<void> log(AnalyticsEvent event) =>
      _analytics.logEvent(name: event.name, parameters: event.parameters);

  @override
  Future<void> screen(String name) =>
      _analytics.logScreenView(screenName: name);

  @override
  Future<void> setCollecting(bool collecting) async {
    if (collecting) {
      await _analytics.setConsent(analyticsStorageConsentGranted: true);
      await _analytics.setAnalyticsCollectionEnabled(true);
    } else {
      await _analytics.setAnalyticsCollectionEnabled(false);
      await _analytics.setConsent(analyticsStorageConsentGranted: false);
    }
  }

  @override
  Future<void> resetDevice() => _analytics.resetAnalyticsData();
}
