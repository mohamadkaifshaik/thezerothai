import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dzeroth/core/network/network_type_service.dart';
import 'package:flutter_test/flutter_test.dart';

class _Connectivity implements Connectivity {
  _Connectivity(this.initial);

  List<ConnectivityResult> initial;
  bool failCheck = false;
  final controller = StreamController<List<ConnectivityResult>>.broadcast(
    sync: true,
  );

  @override
  Stream<List<ConnectivityResult>> get onConnectivityChanged =>
      controller.stream;

  @override
  Future<List<ConnectivityResult>> checkConnectivity() async {
    if (failCheck) throw StateError('no plugin');
    return initial;
  }
}

void main() {
  group('isMeteredConnection', () {
    bool phone(List<ConnectivityResult> r) =>
        isMeteredConnection(r, web: false);

    test('Wi-Fi and ethernet are unmetered', () {
      expect(phone([ConnectivityResult.wifi]), isFalse);
      expect(phone([ConnectivityResult.ethernet]), isFalse);
      expect(phone([ConnectivityResult.vpn, ConnectivityResult.wifi]), isFalse);
      expect(
        phone([ConnectivityResult.mobile, ConnectivityResult.wifi]),
        isFalse,
      );
    });

    test('mobile and anything else on a phone is metered', () {
      expect(phone([ConnectivityResult.mobile]), isTrue);
      expect(phone([ConnectivityResult.vpn]), isTrue);
      expect(phone([ConnectivityResult.other]), isTrue);
      expect(phone([ConnectivityResult.bluetooth]), isTrue);
      expect(phone([ConnectivityResult.none]), isTrue);
      expect(phone(const []), isTrue);
    });

    test('on the web an unknown or mobile type counts as unmetered', () {
      for (final results in [
        [ConnectivityResult.mobile],
        [ConnectivityResult.other],
        [ConnectivityResult.none],
        <ConnectivityResult>[],
      ]) {
        expect(isMeteredConnection(results, web: true), isFalse);
      }
    });
  });

  group('ConnectivityNetworkTypeService', () {
    test('starts metered on a phone, then follows the first check', () async {
      final plugin = _Connectivity([ConnectivityResult.wifi]);
      final service = ConnectivityNetworkTypeService(
        connectivity: plugin,
        web: false,
      );
      addTearDown(service.dispose);
      expect(service.metered, isTrue);
      expect(service.canDistinguish, isTrue);
      await Future<void>.delayed(Duration.zero);
      expect(service.metered, isFalse);
    });

    test('emits changes once, never repeats a value', () async {
      final plugin = _Connectivity([ConnectivityResult.wifi]);
      final service = ConnectivityNetworkTypeService(
        connectivity: plugin,
        web: false,
      );
      addTearDown(service.dispose);
      await Future<void>.delayed(Duration.zero);
      final seen = <bool>[];
      final sub = service.meteredChanges.listen(seen.add);
      addTearDown(sub.cancel);
      plugin.controller.add([ConnectivityResult.mobile]);
      plugin.controller.add([ConnectivityResult.mobile]);
      plugin.controller.add([ConnectivityResult.ethernet]);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [true, false]);
    });

    test('on the web it is unmetered and cannot tell', () async {
      final service = ConnectivityNetworkTypeService(
        connectivity: _Connectivity([ConnectivityResult.mobile]),
        web: true,
      );
      addTearDown(service.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(service.metered, isFalse);
      expect(service.canDistinguish, isFalse);
    });

    test('a failing plugin keeps the last value and never throws', () async {
      final plugin = _Connectivity(const [])..failCheck = true;
      final service = ConnectivityNetworkTypeService(
        connectivity: plugin,
        web: false,
      );
      addTearDown(service.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(service.metered, isTrue);
    });
  });

  group('online / offline', () {
    test('only no result at all counts as offline', () {
      expect(isOfflineConnection(const []), isTrue);
      expect(isOfflineConnection([ConnectivityResult.none]), isTrue);
      expect(isOfflineConnection([ConnectivityResult.wifi]), isFalse);
      expect(isOfflineConnection([ConnectivityResult.mobile]), isFalse);
      expect(isOfflineConnection([ConnectivityResult.vpn]), isFalse);
      expect(
        isOfflineConnection([ConnectivityResult.none, ConnectivityResult.wifi]),
        isFalse,
      );
    });

    test(
      'online until a check says otherwise; emits each change once',
      () async {
        final plugin = _Connectivity([ConnectivityResult.wifi]);
        final service = ConnectivityNetworkTypeService(
          connectivity: plugin,
          web: false,
        );
        addTearDown(service.dispose);
        final seen = <bool>[];
        service.onlineChanges.listen(seen.add);
        expect(service.online, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(seen, isEmpty);

        plugin.controller.add([ConnectivityResult.none]);
        plugin.controller.add([ConnectivityResult.none]);
        expect(service.online, isFalse);
        plugin.controller.add([ConnectivityResult.mobile]);
        expect(service.online, isTrue);
        await Future<void>.delayed(Duration.zero);
        expect(seen, [false, true]);
      },
    );

    test('a phone that starts offline says so after the first check', () async {
      final plugin = _Connectivity([ConnectivityResult.none]);
      final service = ConnectivityNetworkTypeService(
        connectivity: plugin,
        web: false,
      );
      addTearDown(service.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(service.online, isFalse);
    });

    test('a failing plugin leaves the device online', () async {
      final plugin = _Connectivity(const [])..failCheck = true;
      final service = ConnectivityNetworkTypeService(
        connectivity: plugin,
        web: false,
      );
      addTearDown(service.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(service.online, isTrue);
    });
  });
}
