import 'dart:async';

import 'package:dzeroth/core/network/network_type_service.dart';

/// A scripted [NetworkTypeService]: [setMetered] changes the type,
/// [setOnline] the connection.
class FakeNetworkTypeService implements NetworkTypeService {
  FakeNetworkTypeService({
    bool metered = false,
    this.canDistinguish = true,
    bool online = true,
  }) : _metered = metered,
       _online = online;

  bool _metered;
  bool _online;
  final _onlineChanges = StreamController<bool>.broadcast(sync: true);
  final _changes = StreamController<bool>.broadcast(sync: true);
  bool disposed = false;

  @override
  final bool canDistinguish;

  @override
  bool get metered => _metered;

  @override
  Stream<bool> get meteredChanges => _changes.stream;

  @override
  bool get online => _online;

  @override
  Stream<bool> get onlineChanges => _onlineChanges.stream;

  void setOnline(bool value) {
    if (value == _online) return;
    _online = value;
    _onlineChanges.add(value);
  }

  void setMetered(bool value) {
    if (value == _metered) return;
    _metered = value;
    _changes.add(value);
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(_changes.close());
    unawaited(_onlineChanges.close());
  }
}
