import 'dart:async';

import 'package:dzeroth/core/network/network_type_service.dart';

/// A scripted [NetworkTypeService]: [setMetered] changes the type.
class FakeNetworkTypeService implements NetworkTypeService {
  FakeNetworkTypeService({bool metered = false, this.canDistinguish = true})
    : _metered = metered;

  bool _metered;
  final _changes = StreamController<bool>.broadcast(sync: true);
  bool disposed = false;

  @override
  final bool canDistinguish;

  @override
  bool get metered => _metered;

  @override
  Stream<bool> get meteredChanges => _changes.stream;

  void setMetered(bool value) {
    if (value == _metered) return;
    _metered = value;
    _changes.add(value);
  }

  @override
  void dispose() {
    disposed = true;
    unawaited(_changes.close());
  }
}
